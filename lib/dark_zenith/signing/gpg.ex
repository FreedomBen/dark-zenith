defmodule DarkZenith.Signing.Gpg do
  @moduledoc """
  The real metadata-signing implementation (DESIGN.md: Repository metadata
  signing): decrypts the owner's private key from its envelope — falling
  back to `PREVIOUS_SECRET_KEY_BASE` during rotation — and produces a
  detached armored signature over the exact `repomd.xml` bytes inside an
  ephemeral `GNUPGHOME`, forcing the exact signing fingerprint.

  An expired key fails closed with `{:error, :expired}` (the spec's
  non-retryable `conflict_gpg_key_expired`); a missing, undecryptable, or
  otherwise unusable key reports `{:error, :unavailable}`.
  """

  @behaviour DarkZenith.Signing

  alias DarkZenith.Crypto.GpgKeyEnvelope
  alias DarkZenith.Gpg

  @impl true
  def sign_repomd(owner, repomd_xml) do
    cond do
      is_nil(owner.gpg_key_private) or is_nil(owner.gpg_signing_fingerprint) ->
        {:error, :unavailable}

      expired?(owner) ->
        {:error, :expired}

      true ->
        with {:ok, private_armored} <- GpgKeyEnvelope.decrypt(owner.gpg_key_private, owner.id),
             {:ok, signature} <-
               Gpg.sign_detached(private_armored, owner.gpg_signing_fingerprint, repomd_xml) do
          {:ok, signature}
        else
          _other -> {:error, :unavailable}
        end
    end
  end

  @impl true
  def sign_rpm(owner, source_path, workdir, format) do
    cond do
      is_nil(owner.gpg_key_private) or is_nil(owner.gpg_signing_fingerprint) ->
        {:error, :unavailable}

      expired?(owner) ->
        {:error, :expired}

      true ->
        with {:ok, private_armored} <- decrypt(owner) do
          do_sign_rpm(owner, private_armored, source_path, workdir, format)
        end
    end
  end

  defp decrypt(owner) do
    case GpgKeyEnvelope.decrypt(owner.gpg_key_private, owner.id) do
      {:ok, private_armored} -> {:ok, private_armored}
      _other -> {:error, :unavailable}
    end
  end

  # DESIGN.md: RPM signing steps 2–5. The working copy is signed with
  # rpmsign against an ephemeral GNUPGHOME (argument vectors only), then
  # verified in an isolated RPM database: every digest OK plus at least one
  # OK signature; anything else rejects.
  defp do_sign_rpm(owner, private_armored, source_path, workdir, format) do
    home = Path.join(workdir, "gnupg")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)

    signed_path = Path.join(workdir, "signed.rpm")
    File.cp!(source_path, signed_path)
    File.chmod!(signed_path, 0o600)

    gpg_path = Application.get_env(:dark_zenith, :gpg_path, "gpg")
    rpmsign = Application.get_env(:dark_zenith, :rpmsign_path, "rpmsign")

    with :ok <- import_private(gpg_path, home, private_armored, workdir),
         :ok <- run_rpmsign(rpmsign, home, signed_path, owner.gpg_signing_fingerprint, format),
         :ok <- verify_signed(owner, workdir, signed_path) do
      {:ok, signed_path}
    end
  end

  defp import_private(gpg_path, home, private_armored, workdir) do
    key_path = Path.join(workdir, "signing-key.asc")
    File.write!(key_path, private_armored)
    File.chmod!(key_path, 0o600)

    case run_cmd(gpg_path, ["--homedir", home, "--batch", "--import", key_path]) do
      {:ok, _} -> :ok
      {:error, :missing_tool} -> {:error, :unavailable}
      {:error, _} -> {:error, :unavailable}
    end
  after
    File.rm(Path.join(workdir, "signing-key.asc"))
  end

  defp run_rpmsign(rpmsign, home, signed_path, signing_fingerprint, format) do
    # Existing OpenPGP package signatures are replaced (--resign); unsigned
    # inputs are signed (--addsign). --resign handles both on RPM 6.
    format_args = if format == 6, do: ["--rpmv4"], else: []

    args =
      format_args ++
        [
          "--define",
          "_gpg_path #{home}",
          "--key-id",
          signing_fingerprint <> "!",
          "--resign",
          signed_path
        ]

    case run_cmd(rpmsign, args) do
      {:ok, _} -> :ok
      {:error, :missing_tool} -> {:error, :unavailable}
      {:error, _} -> {:error, :validation_failed}
    end
  end

  defp verify_signed(owner, workdir, signed_path) do
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")
    dbpath = Path.join(workdir, "verify-rpmdb")
    File.mkdir_p!(dbpath)
    public_path = Path.join(workdir, "owner-public.asc")
    File.write!(public_path, owner.gpg_key_public)

    with {:ok, _} <- import_public(rpmkeys, dbpath, public_path),
         {:ok, output} <-
           run_cmd(rpmkeys, ["--dbpath", dbpath, "--checksig", "--verbose", signed_path]) do
      analyze_signed_output(output)
    else
      {:error, :missing_tool} -> {:error, :rpm_verification_unavailable}
      # Keyring creation/import failure for an already-validated key is a
      # signing-infrastructure problem, not a package problem.
      {:error, {:import, _}} -> {:error, :unavailable}
      {:error, _} -> {:error, :validation_failed}
    end
  end

  defp import_public(rpmkeys, dbpath, public_path) do
    case run_cmd(rpmkeys, ["--dbpath", dbpath, "--import", public_path]) do
      {:ok, output} -> {:ok, output}
      {:error, :missing_tool} -> {:error, :missing_tool}
      {:error, reason} -> {:error, {:import, reason}}
    end
  end

  defp analyze_signed_output(output) do
    lines =
      for line <- String.split(output, "\n"),
          match = Regex.run(~r/^\s+(.+?):\s+(OK|BAD|NOTFOUND|NOKEY)\b/, line),
          do: {Enum.at(match, 1), Enum.at(match, 2)}

    # NOTFOUND marks an absent digest, not a failed one; every digest that
    # is present must report OK.
    digests_ok? =
      Enum.any?(lines, fn {name, status} ->
        String.contains?(String.downcase(name), "digest") and status == "OK"
      end) and
        not Enum.any?(lines, fn {name, status} ->
          String.contains?(String.downcase(name), "digest") and status not in ["OK", "NOTFOUND"]
        end)

    signature_ok? =
      Enum.any?(lines, fn {name, status} ->
        String.contains?(String.downcase(name), "signature") and status == "OK"
      end)

    any_bad? = Enum.any?(lines, fn {_name, status} -> status == "BAD" end)

    if digests_ok? and signature_ok? and not any_bad? do
      :ok
    else
      {:error, :validation_failed}
    end
  end

  defp run_cmd(binary, args) do
    case System.cmd(binary, args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  rescue
    ErlangError -> {:error, :missing_tool}
  end

  defp expired?(%{gpg_key_expires_at: nil}), do: false

  defp expired?(%{gpg_key_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
