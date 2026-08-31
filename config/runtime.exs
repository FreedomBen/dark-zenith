import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/dark_zenith start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :dark_zenith, DarkZenithWeb.Endpoint, server: true
end

# An explicit PORT wins in every environment; per-environment defaults live in
# dev.exs/test.exs, and production falls back to 4000 below (DESIGN.md:
# Configuration).
if port = System.get_env("PORT") do
  config :dark_zenith, DarkZenithWeb.Endpoint, http: [port: String.to_integer(port)]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :dark_zenith, DarkZenithWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/dark_zenith_web/router\.ex$"E,
        ~r"lib/dark_zenith_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dark_zenith, DarkZenith.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # SECRET_KEY_BASE is also the root key material for token hashing and the
  # GPG-key encryption envelope; PREVIOUS_SECRET_KEY_BASE supports the
  # documented rotation window (DESIGN.md: Configuration; GPG private key
  # encryption). Both are raw UTF-8 bytes, validated before boot proceeds.
  previous_secret_key_base = System.get_env("PREVIOUS_SECRET_KEY_BASE")

  case DarkZenith.Crypto.validate_secret_key_bases(secret_key_base, previous_secret_key_base) do
    :ok -> :ok
    {:error, reason} -> raise "invalid SECRET_KEY_BASE configuration: #{reason}"
  end

  config :dark_zenith,
    secret_key_base: secret_key_base,
    previous_secret_key_base: previous_secret_key_base

  config :dark_zenith,
    registration_enabled: System.get_env("REGISTRATION_ENABLED") in ~w(true 1)

  config :dark_zenith,
    bootstrap_admin: [
      email: System.get_env("ADMIN_EMAIL"),
      password: System.get_env("ADMIN_PASSWORD")
    ]

  max_user_api_keys =
    case Integer.parse(System.get_env("MAX_USER_API_KEYS") || "100") do
      {value, ""} when value >= 1 -> value
      _ -> raise "MAX_USER_API_KEYS must be a positive integer"
    end

  config :dark_zenith, max_user_api_keys: max_user_api_keys

  # 0 disables the combined collaborator/invitation limit per repository.
  max_repository_collaborators =
    case Integer.parse(System.get_env("MAX_REPOSITORY_COLLABORATORS") || "1000") do
      {value, ""} when value >= 0 -> value
      _ -> raise "MAX_REPOSITORY_COLLABORATORS must be a non-negative integer"
    end

  config :dark_zenith, max_repository_collaborators: max_repository_collaborators

  # 0 disables invitation expiry (expires_at stored as null).
  invitation_expiry_days =
    case Integer.parse(System.get_env("INVITATION_EXPIRY_DAYS") || "30") do
      {value, ""} when value >= 0 -> value
      _ -> raise "INVITATION_EXPIRY_DAYS must be a non-negative integer"
    end

  config :dark_zenith, invitation_expiry_days: invitation_expiry_days

  max_repository_packages =
    case Integer.parse(System.get_env("MAX_REPOSITORY_PACKAGES") || "10000") do
      {value, ""} when value >= 1 -> value
      _ -> raise "MAX_REPOSITORY_PACKAGES must be a positive integer"
    end

  config :dark_zenith, max_repository_packages: max_repository_packages

  max_repodata_open_bytes =
    case Integer.parse(System.get_env("MAX_REPODATA_OPEN_BYTES") || "268435456") do
      {value, ""} when value >= 1 -> value
      _ -> raise "MAX_REPODATA_OPEN_BYTES must be a positive integer"
    end

  config :dark_zenith, max_repodata_open_bytes: max_repodata_open_bytes

  signing_preparation_batch_size =
    case Integer.parse(System.get_env("SIGNING_PREPARATION_BATCH_SIZE") || "1000") do
      {value, ""} when value >= 1 and value <= 10_000 -> value
      _ -> raise "SIGNING_PREPARATION_BATCH_SIZE must be an integer from 1 through 10000"
    end

  config :dark_zenith, signing_preparation_batch_size: signing_preparation_batch_size

  rpm_tool_timeout_seconds =
    case Integer.parse(System.get_env("RPM_TOOL_TIMEOUT_SECONDS") || "1800") do
      {value, ""} when value >= 1 -> value
      _ -> raise "RPM_TOOL_TIMEOUT_SECONDS must be a positive integer"
    end

  config :dark_zenith, rpm_tool_timeout_seconds: rpm_tool_timeout_seconds

  if tmpdir = System.get_env("RPM_UPLOAD_TMPDIR") do
    config :dark_zenith, rpm_upload_tmpdir: tmpdir
  end

  max_rpm_upload_bytes =
    case Integer.parse(System.get_env("MAX_RPM_UPLOAD_BYTES") || "536870912") do
      {value, ""} when value >= 1 and value <= 5_368_709_120 -> value
      _ -> raise "MAX_RPM_UPLOAD_BYTES must be an integer from 1 through 5368709120"
    end

  config :dark_zenith, max_rpm_upload_bytes: max_rpm_upload_bytes

  # 0 disables the per-user storage quota.
  max_user_storage_bytes =
    case Integer.parse(System.get_env("MAX_USER_STORAGE_BYTES") || "53687091200") do
      {value, ""} when value >= 0 -> value
      _ -> raise "MAX_USER_STORAGE_BYTES must be a non-negative integer"
    end

  config :dark_zenith, max_user_storage_bytes: max_user_storage_bytes

  # B2 storage settings: all five are required together once any is set.
  b2_vars = ~w(B2_KEY_ID B2_APPLICATION_KEY B2_BUCKET B2_ENDPOINT B2_REGION)
  b2_values = Enum.map(b2_vars, &System.get_env/1)

  cond do
    Enum.all?(b2_values, &is_binary/1) ->
      [key_id, application_key, bucket, endpoint, region] = b2_values

      config :dark_zenith, :b2,
        key_id: key_id,
        application_key: application_key,
        bucket: bucket,
        endpoint: endpoint,
        region: region

    Enum.any?(b2_values, &is_binary/1) ->
      missing = b2_vars |> Enum.zip(b2_values) |> Enum.filter(fn {_, v} -> is_nil(v) end)
      raise "incomplete B2 configuration; missing #{inspect(Enum.map(missing, &elem(&1, 0)))}"

    true ->
      :ok
  end

  b2_signed_url_ttl =
    case Integer.parse(System.get_env("B2_SIGNED_URL_TTL") || "1800") do
      {value, ""} when value >= 1 and value <= 604_800 -> value
      _ -> raise "B2_SIGNED_URL_TTL must be an integer from 1 through 604800"
    end

  config :dark_zenith, b2_signed_url_ttl: b2_signed_url_ttl

  b2_upload_url_ttl =
    case Integer.parse(System.get_env("B2_UPLOAD_URL_TTL") || "3600") do
      {value, ""} when value >= 60 and value <= 3600 -> value
      _ -> raise "B2_UPLOAD_URL_TTL must be an integer from 60 through 3600"
    end

  config :dark_zenith, b2_upload_url_ttl: b2_upload_url_ttl

  # Outbound mail (DESIGN.md: Email Delivery). Unknown aliases refuse boot.
  mail_adapter_alias = System.get_env("MAIL_ADAPTER") || "zepto"
  mail_adapter = DarkZenith.Mail.adapter_for(mail_adapter_alias)

  mail_from_address =
    System.get_env("MAIL_FROM_ADDRESS") ||
      raise "MAIL_FROM_ADDRESS is required for outbound notifications"

  config :dark_zenith,
         :mail_from,
         {System.get_env("MAIL_FROM_NAME") || "Dark Zenith", mail_from_address}

  case mail_adapter_alias do
    "zepto" ->
      api_key =
        System.get_env("ZEPTO_API_KEY") ||
          raise "ZEPTO_API_KEY is required when MAIL_ADAPTER=zepto"

      config :dark_zenith, DarkZenith.Mailer, adapter: mail_adapter, api_key: api_key
      config :swoosh, :api_client, Swoosh.ApiClient.Req

    "smtp" ->
      relay = System.get_env("SMTP_HOST") || raise "SMTP_HOST is required when MAIL_ADAPTER=smtp"

      port =
        case Integer.parse(System.get_env("SMTP_PORT") || "587") do
          {value, ""} when value in 1..65_535 -> value
          _ -> raise "SMTP_PORT must be a port number"
        end

      config :dark_zenith, DarkZenith.Mailer,
        adapter: mail_adapter,
        relay: relay,
        port: port,
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        ssl: System.get_env("SMTP_SSL") in ~w(true 1),
        tls: :if_available,
        auth: :if_available

    "local" ->
      config :dark_zenith, DarkZenith.Mailer, adapter: mail_adapter
  end

  # Public URL used in generated links and the browser-upload CORS origin
  # (DESIGN.md: Configuration). PHX_SCHEME=http supports local deployments.
  host = System.get_env("PHX_HOST") || "example.com"

  url_scheme =
    case System.get_env("PHX_SCHEME") || "https" do
      scheme when scheme in ["http", "https"] -> scheme
      other -> raise "PHX_SCHEME must be http or https, got: #{inspect(other)}"
    end

  url_port =
    case Integer.parse(System.get_env("PHX_URL_PORT") || "443") do
      {value, ""} when value in 1..65_535 -> value
      _ -> raise "PHX_URL_PORT must be a port number"
    end

  config :dark_zenith, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :dark_zenith,
         :trusted_proxies,
         DarkZenith.ClientIp.parse_trusted_proxies(System.get_env("TRUSTED_PROXIES") || "")

  config :dark_zenith, DarkZenithWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dark_zenith, DarkZenithWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dark_zenith, DarkZenithWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :dark_zenith, DarkZenith.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
