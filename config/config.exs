# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dark_zenith, :scopes,
  user: [
    default: true,
    module: DarkZenith.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: DarkZenith.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :dark_zenith,
  ecto_repos: [DarkZenith.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Whether new account registration is open (DESIGN.md: REGISTRATION_ENABLED,
# default false). Overridden per environment and by runtime.exs in production.
config :dark_zenith, registration_enabled: false

# Background jobs (DESIGN.md: Oban runs metadata regeneration, upload/re-sign
# processing, B2 cleanup, and email delivery). The rpm_processing queue
# concurrency is overridden at runtime by RPM_PROCESSING_CONCURRENCY.
config :dark_zenith, Oban,
  engine: Oban.Engines.Basic,
  repo: DarkZenith.Repo,
  queues: [default: 10, rpm_processing: 2, metadata: 10, cleanup: 10, mailers: 20],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 604_800},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", DarkZenith.Workers.SessionTokenCleanup},
       {"0 * * * *", DarkZenith.Workers.InvitationCleanup}
     ]}
  ]

# Configure the endpoint
config :dark_zenith, DarkZenithWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DarkZenithWeb.ErrorHTML, json: DarkZenithWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DarkZenith.PubSub,
  live_view: [signing_salt: "jAbW9ijE"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dark_zenith, DarkZenith.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dark_zenith: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  dark_zenith: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
