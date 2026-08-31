import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dark_zenith, DarkZenith.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 55432,
  database: "dark_zenith_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dark_zenith, DarkZenithWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "X7VaVGDZmih3+i42wNFyWajPS3FrJNC+WCfEl0LKPdwZ4fLYchFg6joJ767rloXD",
  server: false

# Most tests exercise open registration; the disabled default is covered by
# dedicated tests that override this value.
config :dark_zenith, registration_enabled: true

# Tests drive the bootstrap functions directly rather than at app boot.
config :dark_zenith, bootstrap_admin_on_boot: false

# Root key material for token hashing and the GPG-key encryption envelope,
# mirroring the endpoint secret_key_base above.
config :dark_zenith,
  secret_key_base: "X7VaVGDZmih3+i42wNFyWajPS3FrJNC+WCfEl0LKPdwZ4fLYchFg6joJ767rloXD"

# Oban: insert jobs without executing them; tests assert on enqueued jobs
# or drain queues explicitly.
config :dark_zenith, Oban, testing: :manual

# In test we don't send emails
config :dark_zenith, DarkZenith.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The SQL sandbox wraps each test in an outer transaction, where a late SET
# TRANSACTION ISOLATION LEVEL is rejected by PostgreSQL; the regeneration
# job skips it in test.
config :dark_zenith, metadata_snapshot_isolation: false

# B2 requests in test go through the Req.Test stub plug.
config :dark_zenith, :b2,
  key_id: "test-key-id",
  application_key: "test-secret",
  bucket: "dz-bucket",
  endpoint: "https://s3.test.invalid",
  region: "test-region",
  req_options: [plug: {Req.Test, DarkZenith.B2Stub}, retry: false]

# rpmsign is not always installed in dev/test machines; the per-key RPM
# fixture-compatibility check is stubbed and exercised for real only where
# rpm-sign exists (tagged :rpmsign integration test).
config :dark_zenith, gpg_rpm_compat_impl: DarkZenith.GpgRpmCompatStub
