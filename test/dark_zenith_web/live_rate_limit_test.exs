defmodule DarkZenithWeb.LiveRateLimitTest do
  # Not async: tightens the global rate-limit overrides.
  use DarkZenithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  setup do
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)
    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)
    :ets.delete_all_objects(DarkZenith.RateLimit)
    %{previous: previous}
  end

  test "specialized LiveView events consume their hourly bucket", ctx do
    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.merge(ctx.previous, %{api_key_create: {1, 3600}})
    )

    user = user_fixture()
    {:ok, lv, _html} = build_conn() |> log_in_user(user) |> live(~p"/users/settings")

    submit = fn ->
      lv
      |> form("#create_api_key_form", api_key: %{"name" => "k", "scopes" => ["repo:read"]})
      |> render_submit()
    end

    submit.()
    assert length(DarkZenith.Accounts.list_api_keys(user)) == 1

    # The second event is rejected before its handler runs.
    html = submit.()
    assert html =~ "Too many requests"
    assert length(DarkZenith.Accounts.list_api_keys(user)) == 1
  end

  test "registration submits use the auth-attempt email bucket", ctx do
    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.merge(ctx.previous, %{auth_attempt_ip: {100, 60}, auth_attempt_email: {1, 60}})
    )

    {:ok, lv, _html} = live(build_conn(), ~p"/users/register")

    # An invalid password consumes the attempt slots without registering,
    # keeping the LiveView alive for the second submit.
    submit = fn ->
      lv
      |> form("#registration_form",
        user: %{"email" => "bucketed@example.com", "password" => "short"}
      )
      |> render_submit()
    end

    submit.()
    html = submit.()
    assert html =~ "Too many requests"
    refute DarkZenith.Accounts.get_user_by_email("bucketed@example.com")
  end
end
