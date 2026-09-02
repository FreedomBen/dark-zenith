defmodule DarkZenith.BootCheck do
  @moduledoc """
  Boot-time environment validation (DESIGN.md: Deployment).

  Resolves `RPMKEYS_PATH`, requires RPM 6.0 or newer from its version probe
  under `LC_ALL=C`, and verifies the pristine bundled strong-digest v4/v6
  fixtures to detect unusable policy/tool combinations. Probes configured
  signing executables when present (their absence only degrades GPG key
  upload to `503`). Differentially checks the PostgreSQL EVR comparator
  against the RPM tooling for the conformance corpus, and validates that
  the configured mail adapter module is loadable. In production a failed
  required check refuses boot.
  """

  require Logger

  @evr_probe [
    {"1.0", "2.0", -1},
    {"10.0001", "10.1", 0},
    {"1.0~rc1", "1.0", -1},
    {"1.0^git1", "1.0", 1},
    {"1.0^git1", "1.01", -1},
    {"5.5p10", "5.5p1", 1},
    {"10b2", "10a1", 1},
    {"2.0", "2_0", 0}
  ]

  @doc """
  Runs every check. Returns `:ok` or `{:error, failures}` with one entry
  per failed check.
  """
  def run do
    failures =
      Enum.reject(
        [
          {"rpmkeys version", check_rpmkeys_version()},
          {"rpmkeys fixture verification", check_fixture_verification()},
          {"EVR comparator differential", check_evr_comparator()},
          {"mail adapter", check_mail_adapter()},
          {"signing tools", probe_signing_tools()}
        ],
        fn {_name, result} -> result == :ok end
      )

    case failures do
      [] -> :ok
      failures -> {:error, Enum.map(failures, fn {name, {:error, reason}} -> {name, reason} end)}
    end
  end

  @doc "Runs the checks and raises on failure — the release-gate entry point."
  def run! do
    case run() do
      :ok ->
        Logger.info("boot checks passed")
        :ok

      {:error, failures} ->
        raise "boot checks failed: #{inspect(failures)}"
    end
  end

  @doc "RPM 6.0+ is required because every upload is verified with rpmkeys."
  def check_rpmkeys_version do
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")

    case run_cmd(rpmkeys, ["--version"]) do
      {:ok, output} ->
        case Regex.run(~r/RPM version (\d+)\.(\d+)/, output) do
          [_, major, _minor] ->
            if String.to_integer(major) >= 6 do
              :ok
            else
              {:error, "rpmkeys reports #{String.trim(output)}; RPM 6.0 or newer is required"}
            end

          nil ->
            {:error, "could not parse rpmkeys version output"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verifies the bundled strong-digest fixtures with an isolated database
  under `RPM_UPLOAD_TMPDIR`, which also proves that directory is writable.
  """
  def check_fixture_verification do
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")
    base = Application.get_env(:dark_zenith, :rpm_upload_tmpdir) || System.tmp_dir!()
    dbpath = Path.join(base, "dz-bootcheck-#{System.unique_integer([:positive])}")

    case File.mkdir_p(dbpath) do
      :ok ->
        try do
          verify_fixtures(rpmkeys, dbpath)
        after
          File.rm_rf(dbpath)
        end

      {:error, reason} ->
        {:error,
         "cannot create #{dbpath}: #{:file.format_error(reason)}; " <>
           "RPM_UPLOAD_TMPDIR must be a directory writable by the application user"}
    end
  end

  defp verify_fixtures(rpmkeys, dbpath) do
    fixture_dir = Application.app_dir(:dark_zenith, "priv/rpm_fixtures")

    Enum.reduce_while(["dz-fixture-v4.rpm", "dz-fixture-v6.rpm"], :ok, fn fixture, :ok ->
      path = Path.join(fixture_dir, fixture)

      case run_cmd(rpmkeys, ["--dbpath", dbpath, "--checksig", "--verbose", path]) do
        {:ok, output} ->
          if output =~ "digest: OK" and not (output =~ " BAD") do
            {:cont, :ok}
          else
            {:halt, {:error, "#{fixture} failed verification: #{String.trim(output)}"}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Differentially compares `dark_zenith_rpmvercmp` with the RPM tooling
  (`rpm --eval` Lua `rpm.vercmp`) across probe pairs, catching comparator
  or operator-class drift before serving version-ordered results.
  """
  def check_evr_comparator do
    rpm = rpm_binary()

    Enum.reduce_while(@evr_probe, :ok, fn {a, b, expected}, :ok ->
      sql =
        DarkZenith.Repo.query!("SELECT dark_zenith_rpmvercmp($1, $2)", [a, b]).rows
        |> hd()
        |> hd()

      tool =
        case run_cmd(rpm, ["--eval", "%{lua: print(rpm.vercmp('#{a}','#{b}'))}"]) do
          {:ok, output} -> output |> String.trim() |> String.to_integer()
          {:error, reason} -> {:error, reason}
        end

      cond do
        match?({:error, _}, tool) -> {:halt, tool}
        sql != expected -> {:halt, {:error, "SQL comparator disagrees on #{a} vs #{b}"}}
        tool != expected -> {:halt, {:error, "RPM tooling disagrees on #{a} vs #{b}"}}
        true -> {:cont, :ok}
      end
    end)
  end

  @doc "The configured Swoosh adapter module must be loadable."
  def check_mail_adapter do
    config = Application.get_env(:dark_zenith, DarkZenith.Mailer, [])

    case Keyword.get(config, :adapter) do
      nil -> {:error, "no mail adapter configured"}
      adapter -> if Code.ensure_loaded?(adapter), do: :ok, else: {:error, "unknown adapter"}
    end
  end

  @doc """
  Probes configured signing executables when present; absence is logged
  rather than fatal, since it only degrades GPG key upload to 503.
  """
  def probe_signing_tools do
    for {label, key, default} <- [
          {"gpg", :gpg_path, "gpg"},
          {"rpmsign", :rpmsign_path, "rpmsign"}
        ] do
      path = Application.get_env(:dark_zenith, key, default)

      case run_cmd(path, ["--version"]) do
        {:ok, output} ->
          Logger.info("boot probe #{label}: #{output |> String.split("\n") |> hd()}")

        {:error, _} ->
          Logger.warning(
            "boot probe: #{label} is unavailable; GPG key upload will return signing_unavailable"
          )
      end
    end

    :ok
  end

  @doc """
  Boot child: runs the checks when `:boot_checks_on_boot` is set. A failed
  required check refuses boot — the child start fails, so the supervisor
  and the release never come up half-configured — after logging each
  failing check with its reason. Passing or disabled checks leave no
  process behind.
  """
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  @doc false
  def start_link(_opts \\ []) do
    if Application.get_env(:dark_zenith, :boot_checks_on_boot, false) do
      case run() do
        :ok ->
          Logger.info("boot checks passed")
          :ignore

        {:error, failures} ->
          for {name, reason} <- failures do
            Logger.error("boot check failed: #{name}: #{reason}")
          end

          {:error, {:boot_checks_failed, failures}}
      end
    else
      :ignore
    end
  end

  defp rpm_binary do
    # rpmkeys ships with rpm; derive the sibling `rpm` binary for the Lua
    # differential, falling back to PATH.
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")

    case Path.dirname(rpmkeys) do
      "." -> "rpm"
      dir -> Path.join(dir, "rpm")
    end
  end

  defp run_cmd(binary, args) do
    case System.cmd(binary, args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "#{binary} exited #{status}: #{String.trim(output)}"}
    end
  rescue
    ErlangError -> {:error, "#{binary} is not executable or not found"}
  end
end
