defmodule DarkZenith.Gpg do
  @moduledoc """
  GPG key validation and detached signing (DESIGN.md: GPG Signing).

  Every operation runs inside a fresh mode-0700 ephemeral `GNUPGHOME` under
  `RPM_UPLOAD_TMPDIR`, invoking `gpg` with an argument vector — never a
  shell — and removing the home afterwards. Key uploads accept exactly one
  matching OpenPGP V4 pair whose selected signing key is RSA-3072/4096,
  ECDSA P-256/P-384, or Ed25519, non-interactively usable, and at least 30
  full days from its effective expiry. Signatures always force the exact
  selected fingerprint with GPG's `!` selector.
  """

  @min_expiry_days 30
  @allowed_rsa_bits [3072, 4096]
  @allowed_curves ~w(nistp256 nistp384 ed25519)

  defmodule KeyInfo do
    @moduledoc "The validated key pair's identity and signing selection."
    defstruct [:primary_fingerprint, :signing_fingerprint, :expires_at]
  end

  @doc """
  Validates an armored public/private key pair, returning `{:ok, %KeyInfo{}}`
  or `{:error, reason}` where reason is `:validation_failed` (with the
  class of problem logged, never echoed to clients),
  `:signing_unavailable`, or `:rpm_verification_unavailable`.
  """
  def validate_key_pair(public_armored, private_armored) do
    with_ephemeral_home(fn home ->
      with :ok <- import_key(home, private_armored, "private"),
           :ok <- import_key(home, public_armored, "public"),
           {:ok, secret_listing} <- list_keys(home, "--list-secret-keys"),
           {:ok, public_listing} <- list_keys(home, "--list-keys"),
           {:ok, info} <- analyze(secret_listing, public_listing),
           :ok <- test_signature(home, info.signing_fingerprint),
           :ok <- rpm_compat_check(home, info.signing_fingerprint) do
        {:ok, info}
      end
    end)
  end

  @doc """
  Produces a detached ASCII-armored signature over `payload` with the exact
  signing key, importing the armored private key into an ephemeral home.
  """
  def sign_detached(private_armored, signing_fingerprint, payload) do
    with_ephemeral_home(fn home ->
      payload_path = Path.join(home, "payload")
      signature_path = payload_path <> ".asc"
      File.write!(payload_path, payload)
      File.chmod!(payload_path, 0o600)

      with :ok <- import_key(home, private_armored, "private"),
           {_output, 0} <-
             gpg(home, [
               "--batch",
               "--yes",
               "--pinentry-mode",
               "error",
               "--local-user",
               signing_fingerprint <> "!",
               "--armor",
               "--detach-sign",
               "--output",
               signature_path,
               payload_path
             ]) do
        {:ok, File.read!(signature_path)}
      else
        {:error, :gpg_unavailable} -> {:error, :signing_unavailable}
        _other -> {:error, :signing_failed}
      end
    end)
  end

  @doc """
  Verifies a detached armored signature against a payload and an armored
  public key. A test/diagnostic helper.
  """
  def verify_detached(public_armored, payload, signature_armored) do
    with_ephemeral_home(fn home ->
      payload_path = Path.join(home, "payload")
      signature_path = payload_path <> ".asc"
      File.write!(payload_path, payload)
      File.write!(signature_path, signature_armored)

      with :ok <- import_key(home, public_armored, "public"),
           {_output, 0} <- gpg(home, ["--batch", "--verify", signature_path, payload_path]) do
        :ok
      else
        _ -> {:error, :bad_signature}
      end
    end)
  end

  ## Ephemeral home management

  defp with_ephemeral_home(fun) do
    base = Application.get_env(:dark_zenith, :rpm_upload_tmpdir) || System.tmp_dir!()
    home = Path.join(base, "dz-gnupg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)

    try do
      fun.(home)
    after
      File.rm_rf(home)
    end
  end

  defp gpg(home, args) do
    gpg_path = Application.get_env(:dark_zenith, :gpg_path, "gpg")

    case DarkZenith.ToolRunner.cmd(gpg_path, ["--homedir", home, "--no-tty" | args],
           env: [{"LC_ALL", "C"}]
         ) do
      {:error, :timeout} -> {:error, :gpg_unavailable}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :gpg_unavailable}
    ErlangError -> {:error, :gpg_unavailable}
  end

  defp import_key(home, armored, label) do
    path = Path.join(home, "import-#{label}.asc")
    File.write!(path, armored)
    File.chmod!(path, 0o600)

    case gpg(home, ["--batch", "--import", path]) do
      {_output, 0} -> :ok
      {:error, :gpg_unavailable} -> {:error, :signing_unavailable}
      _other -> {:error, :validation_failed}
    end
  end

  defp list_keys(home, mode) do
    case gpg(home, ["--batch", "--with-colons", "--with-subkey-fingerprints", mode]) do
      {output, 0} -> {:ok, output}
      {:error, :gpg_unavailable} -> {:error, :signing_unavailable}
      _other -> {:error, :validation_failed}
    end
  end

  ## Listing analysis

  defp analyze(secret_listing, public_listing) do
    secret_keys = parse_listing(secret_listing, "sec", "ssb")
    public_keys = parse_listing(public_listing, "pub", "sub")

    with {:ok, secret} <- exactly_one(secret_keys),
         {:ok, public} <- exactly_one(public_keys),
         true <- secret.fingerprint == public.fingerprint || {:error, :validation_failed},
         :ok <- require_v4(secret),
         {:ok, signing_key} <- select_signing_key(secret),
         :ok <- check_algorithm(signing_key),
         {:ok, expires_at} <- effective_expiry(secret, signing_key) do
      {:ok,
       %KeyInfo{
         primary_fingerprint: secret.fingerprint,
         signing_fingerprint: signing_key.fingerprint,
         expires_at: expires_at
       }}
    else
      {:error, _} = error -> error
    end
  end

  defp exactly_one([key]), do: {:ok, key}
  defp exactly_one(_keys), do: {:error, :validation_failed}

  # Each key: %{fingerprint, algo, bits, curve, validity, caps, expires,
  # subkeys: [same]}.
  defp parse_listing(listing, primary_tag, subkey_tag) do
    lines = listing |> String.split("\n") |> Enum.map(&String.split(&1, ":"))

    lines
    |> Enum.reduce({[], nil, nil}, fn fields, {keys, current, pending} ->
      case fields do
        [^primary_tag | _] ->
          keys = if current, do: keys ++ [current], else: keys
          {keys, %{new_key(fields) | subkeys: []}, :primary}

        [^subkey_tag | _] when current != nil ->
          {keys, Map.update!(current, :subkeys, &(&1 ++ [new_key(fields)])), :subkey}

        ["fpr", _, _, _, _, _, _, _, _, fingerprint | _] when current != nil ->
          case pending do
            :primary -> {keys, Map.put(current, :fingerprint, fingerprint), nil}
            :subkey -> {keys, put_last_subkey_fpr(current, fingerprint), nil}
            _ -> {keys, current, pending}
          end

        _other ->
          {keys, current, pending}
      end
    end)
    |> then(fn {keys, current, _} -> if current, do: keys ++ [current], else: keys end)
  end

  # Colon-format fields: capabilities are field 12 and the curve field 17
  # (rest is 0-indexed from field 8).
  defp new_key([_tag, validity, bits, algo, _keyid, _created, expires | rest]) do
    caps = Enum.at(rest, 4, "")
    curve = Enum.at(rest, 9, "")

    %{
      fingerprint: nil,
      validity: validity,
      bits: parse_int(bits),
      algo: parse_int(algo),
      expires: parse_int(expires),
      caps: caps,
      curve: curve,
      subkeys: []
    }
  end

  defp put_last_subkey_fpr(key, fingerprint) do
    Map.update!(key, :subkeys, fn subkeys ->
      List.update_at(subkeys, -1, &Map.put(&1, :fingerprint, fingerprint))
    end)
  end

  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  # V4 fingerprints are 40 hex characters; V5/V6 (64) and V3 (32) reject.
  defp require_v4(%{fingerprint: fingerprint}) when byte_size(fingerprint) == 40, do: :ok
  defp require_v4(_key), do: {:error, :validation_failed}

  # A usable signing-capable primary wins; otherwise exactly one usable
  # signing-capable subkey is required.
  defp select_signing_key(key) do
    cond do
      usable_signer?(key) ->
        {:ok, key}

      true ->
        case Enum.filter(key.subkeys, &usable_signer?/1) do
          [subkey] -> require_v4(subkey) |> and_then(fn -> {:ok, subkey} end)
          _zero_or_many -> {:error, :validation_failed}
        end
    end
  end

  defp and_then(:ok, fun), do: fun.()
  defp and_then(error, _fun), do: error

  defp usable_signer?(key) do
    String.contains?(key.caps, "s") and key.validity not in ["r", "e", "d", "i"] and
      not String.contains?(key.caps, "D")
  end

  defp check_algorithm(%{algo: 1, bits: bits}) when bits in @allowed_rsa_bits, do: :ok
  defp check_algorithm(%{algo: 19, curve: curve}) when curve in ["nistp256", "nistp384"], do: :ok
  defp check_algorithm(%{algo: 22, curve: curve}) when curve in @allowed_curves, do: :ok
  defp check_algorithm(_key), do: {:error, :validation_failed}

  # Earlier of the primary and signing-key expirations, ignoring a missing
  # expiration on either; at least 30 full days must remain.
  defp effective_expiry(primary, signing_key) do
    expires =
      [primary.expires, signing_key.expires]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> Enum.min(values)
      end

    case expires do
      nil ->
        {:ok, nil}

      epoch ->
        expires_at = DateTime.from_unix!(epoch)

        if DateTime.diff(expires_at, DateTime.utc_now(), :day) >= @min_expiry_days do
          {:ok, expires_at}
        else
          {:error, :validation_failed}
        end
    end
  end

  # The exact-key test signature also proves non-interactive usability:
  # passphrase-protected or policy-disabled keys fail here.
  defp test_signature(home, signing_fingerprint) do
    payload = Path.join(home, "probe")
    File.write!(payload, "dark-zenith-signing-probe")

    case gpg(home, [
           "--batch",
           "--yes",
           "--pinentry-mode",
           "error",
           "--local-user",
           signing_fingerprint <> "!",
           "--armor",
           "--detach-sign",
           "--output",
           payload <> ".asc",
           payload
         ]) do
      {_output, 0} -> :ok
      {:error, :gpg_unavailable} -> {:error, :signing_unavailable}
      _other -> {:error, :validation_failed}
    end
  end

  # RPM 6 fixture signing compatibility (rpmsign + rpmkeys). Dispatchable so
  # environments without rpm-sign can substitute; the default is the real
  # check.
  defp rpm_compat_check(home, signing_fingerprint) do
    impl = Application.get_env(:dark_zenith, :gpg_rpm_compat_impl, DarkZenith.Gpg.RpmCompat)
    impl.check(home, signing_fingerprint)
  end
end
