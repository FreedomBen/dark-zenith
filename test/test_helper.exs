# The :rpmsign-tagged integration test needs the rpm-sign tool installed.
exclude = if System.find_executable("rpmsign"), do: [], else: [:rpmsign]

# The FIPS-mode test profile (DESIGN.md: GPG Signing; RPM Parsing)
# self-enables when the host kernel reports FIPS mode; elsewhere the
# :fips-tagged tests are excluded.
fips_enabled? =
  case File.read("/proc/sys/crypto/fips_enabled") do
    {:ok, contents} -> String.trim(contents) == "1"
    _ -> false
  end

exclude = if fips_enabled?, do: exclude, else: [:fips | exclude]

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(DarkZenith.Repo, :manual)
