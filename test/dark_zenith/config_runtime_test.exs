defmodule DarkZenith.ConfigRuntimeTest do
  # Evaluates config/runtime.exs the way a release boot does. Environment
  # variables are process-global, so this suite cannot run async.
  use ExUnit.Case, async: false

  @managed_vars ~w(
    DATABASE_URL SECRET_KEY_BASE MAIL_ADAPTER MAIL_FROM_ADDRESS
    PHX_HOST PHX_SCHEME PHX_URL_PORT PHX_SERVER PORT
    MAX_USER_REPOSITORIES RPM_PROCESSING_CONCURRENCY
    RPMKEYS_PATH RPMSIGN_PATH GPG_PATH
    RPM_TOOL_TIMEOUT_SECONDS MAX_REPOSITORY_PACKAGES
  )

  @required_env %{
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/dark_zenith",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "MAIL_ADAPTER" => "local",
    "MAIL_FROM_ADDRESS" => "noreply@example.com"
  }

  setup do
    saved = Map.new(@managed_vars, fn name -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp read_prod_config(extra_env) do
    Enum.each(@managed_vars, &System.delete_env/1)
    System.put_env(Map.merge(@required_env, extra_env))
    Config.Reader.read!("config/runtime.exs", env: :prod)
  end

  defp endpoint_url(config) do
    config |> get_in([:dark_zenith, DarkZenithWeb.Endpoint]) |> Keyword.fetch!(:url)
  end

  test "public URL defaults to https on 443" do
    url = endpoint_url(read_prod_config(%{"PHX_HOST" => "repo.example.com"}))

    assert url[:host] == "repo.example.com"
    assert url[:scheme] == "https"
    assert url[:port] == 443
  end

  test "PHX_SCHEME and PHX_URL_PORT configure the public URL for local http" do
    url =
      endpoint_url(
        read_prod_config(%{
          "PHX_HOST" => "localhost",
          "PHX_SCHEME" => "http",
          "PHX_URL_PORT" => "4200"
        })
      )

    assert url[:host] == "localhost"
    assert url[:scheme] == "http"
    assert url[:port] == 4200
  end

  test "rejects a PHX_SCHEME outside http/https" do
    assert_raise RuntimeError, ~r/PHX_SCHEME/, fn ->
      read_prod_config(%{"PHX_SCHEME" => "gopher"})
    end
  end

  test "rejects a non-port PHX_URL_PORT" do
    for value <- ["0", "65536", "https", "44 3"] do
      assert_raise RuntimeError, ~r/PHX_URL_PORT/, fn ->
        read_prod_config(%{"PHX_URL_PORT" => value})
      end
    end
  end

  test "PHX_HOST defaults to localhost" do
    assert endpoint_url(read_prod_config(%{}))[:host] == "localhost"
  end

  test "MAX_USER_REPOSITORIES is wired with 0 disabling the limit" do
    assert get_in(read_prod_config(%{}), [:dark_zenith, :max_user_repositories]) == 100

    config = read_prod_config(%{"MAX_USER_REPOSITORIES" => "0"})
    assert get_in(config, [:dark_zenith, :max_user_repositories]) == 0

    assert_raise RuntimeError, ~r/MAX_USER_REPOSITORIES/, fn ->
      read_prod_config(%{"MAX_USER_REPOSITORIES" => "-1"})
    end
  end

  test "RPM_PROCESSING_CONCURRENCY configures the rpm_processing queue within 1..64" do
    queues = get_in(read_prod_config(%{}), [:dark_zenith, Oban]) |> Keyword.fetch!(:queues)
    assert queues[:rpm_processing] == 2

    config = read_prod_config(%{"RPM_PROCESSING_CONCURRENCY" => "8"})
    queues = get_in(config, [:dark_zenith, Oban]) |> Keyword.fetch!(:queues)
    assert queues[:rpm_processing] == 8

    for value <- ["0", "65", "two"] do
      assert_raise RuntimeError, ~r/RPM_PROCESSING_CONCURRENCY/, fn ->
        read_prod_config(%{"RPM_PROCESSING_CONCURRENCY" => value})
      end
    end
  end

  test "RPMKEYS_PATH, RPMSIGN_PATH, and GPG_PATH are wired with bare-name defaults" do
    config = read_prod_config(%{})
    assert get_in(config, [:dark_zenith, :rpmkeys_path]) == "rpmkeys"
    assert get_in(config, [:dark_zenith, :rpmsign_path]) == "rpmsign"
    assert get_in(config, [:dark_zenith, :gpg_path]) == "gpg"

    config =
      read_prod_config(%{
        "RPMKEYS_PATH" => "/opt/rpm6/bin/rpmkeys",
        "RPMSIGN_PATH" => "/opt/rpm6/bin/rpmsign",
        "GPG_PATH" => "/opt/gnupg/bin/gpg"
      })

    assert get_in(config, [:dark_zenith, :rpmkeys_path]) == "/opt/rpm6/bin/rpmkeys"
    assert get_in(config, [:dark_zenith, :rpmsign_path]) == "/opt/rpm6/bin/rpmsign"
    assert get_in(config, [:dark_zenith, :gpg_path]) == "/opt/gnupg/bin/gpg"
  end

  test "RPM_TOOL_TIMEOUT_SECONDS must be within 60..7200" do
    config = read_prod_config(%{"RPM_TOOL_TIMEOUT_SECONDS" => "60"})
    assert get_in(config, [:dark_zenith, :rpm_tool_timeout_seconds]) == 60

    config = read_prod_config(%{"RPM_TOOL_TIMEOUT_SECONDS" => "7200"})
    assert get_in(config, [:dark_zenith, :rpm_tool_timeout_seconds]) == 7200

    for value <- ["59", "7201", "1"] do
      assert_raise RuntimeError, ~r/RPM_TOOL_TIMEOUT_SECONDS/, fn ->
        read_prod_config(%{"RPM_TOOL_TIMEOUT_SECONDS" => value})
      end
    end
  end

  test "MAX_REPOSITORY_PACKAGES must be within 1..1000000" do
    config = read_prod_config(%{"MAX_REPOSITORY_PACKAGES" => "1000000"})
    assert get_in(config, [:dark_zenith, :max_repository_packages]) == 1_000_000

    for value <- ["0", "1000001"] do
      assert_raise RuntimeError, ~r/MAX_REPOSITORY_PACKAGES/, fn ->
        read_prod_config(%{"MAX_REPOSITORY_PACKAGES" => value})
      end
    end
  end
end
