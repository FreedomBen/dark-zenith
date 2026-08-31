defmodule DarkZenith.ConfigRuntimeTest do
  # Evaluates config/runtime.exs the way a release boot does. Environment
  # variables are process-global, so this suite cannot run async.
  use ExUnit.Case, async: false

  @managed_vars ~w(
    DATABASE_URL SECRET_KEY_BASE MAIL_ADAPTER MAIL_FROM_ADDRESS
    PHX_HOST PHX_SCHEME PHX_URL_PORT PHX_SERVER PORT
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
end
