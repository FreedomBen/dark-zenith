defmodule DarkZenith.Gpg.RpmCompat do
  @moduledoc """
  Per-key RPM signing compatibility test (DESIGN.md: GPG Signing): signs the
  bundled strongly digested v4 and v6 fixture RPMs with the candidate key
  (`--rpmv4` for the v6 input), imports the public key into an isolated RPM
  database, and requires `rpmkeys` to report the expected signatures and
  every digest OK. Unavailable `rpmsign` maps to `:signing_unavailable`;
  an unavailable verifier to `:rpm_verification_unavailable`.
  """

  def check(home, signing_fingerprint) do
    rpmsign = Application.get_env(:dark_zenith, :rpmsign_path, "rpmsign")
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")

    work = Path.join(home, "rpm-compat")
    File.mkdir_p!(work)
    File.chmod!(work, 0o700)
    dbpath = Path.join(work, "rpmdb")
    File.mkdir_p!(dbpath)

    with :ok <- sign_fixture(rpmsign, home, work, signing_fingerprint, "dz-fixture-v4.rpm", []),
         :ok <-
           sign_fixture(rpmsign, home, work, signing_fingerprint, "dz-fixture-v6.rpm", [
             "--rpmv4"
           ]),
         :ok <- import_public(rpmkeys, home, work, dbpath, signing_fingerprint),
         :ok <- verify_fixture(rpmkeys, dbpath, Path.join(work, "dz-fixture-v4.rpm")),
         :ok <- verify_fixture(rpmkeys, dbpath, Path.join(work, "dz-fixture-v6.rpm")) do
      :ok
    end
  end

  defp sign_fixture(rpmsign, home, work, fingerprint, fixture, extra_args) do
    source = Path.join(Application.app_dir(:dark_zenith, "priv/rpm_fixtures"), fixture)
    target = Path.join(work, fixture)
    File.cp!(source, target)

    args =
      extra_args ++
        [
          "--define",
          "_gpg_name #{fingerprint}!",
          "--define",
          "_gpg_path #{home}",
          "--addsign",
          target
        ]

    case System.cmd(rpmsign, args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _other -> {:error, :validation_failed}
    end
  rescue
    ErlangError -> {:error, :signing_unavailable}
  end

  defp import_public(rpmkeys, home, work, dbpath, fingerprint) do
    gpg_path = Application.get_env(:dark_zenith, :gpg_path, "gpg")
    public_path = Path.join(work, "public.asc")

    with {_out, 0} <-
           System.cmd(
             gpg_path,
             ["--homedir", home, "--batch", "--armor", "--output", public_path, "--export", fingerprint],
             stderr_to_stdout: true
           ),
         {_out, 0} <-
           System.cmd(rpmkeys, ["--dbpath", dbpath, "--import", public_path],
             env: [{"LC_ALL", "C"}],
             stderr_to_stdout: true
           ) do
      :ok
    else
      _other -> {:error, :rpm_verification_unavailable}
    end
  rescue
    ErlangError -> {:error, :rpm_verification_unavailable}
  end

  defp verify_fixture(rpmkeys, dbpath, path) do
    case System.cmd(rpmkeys, ["--dbpath", dbpath, "--checksig", "--verbose", path],
           env: [{"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if output =~ ~r/signature.*: OK/i and not (output =~ " BAD") do
          :ok
        else
          {:error, :validation_failed}
        end

      {_output, _status} ->
        {:error, :validation_failed}
    end
  rescue
    ErlangError -> {:error, :rpm_verification_unavailable}
  end
end
