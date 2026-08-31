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

  test "the GPG generate event consumes the gpg_key_mutation bucket", ctx do
    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.merge(ctx.previous, %{gpg_key_mutation: {0, 3600}})
    )

    user = user_fixture()
    {:ok, lv, _html} = build_conn() |> log_in_user(user) |> live(~p"/users/settings")

    html =
      lv
      |> form("#generate_gpg_key_form", gpg_generation: %{"algorithm" => "ed25519"})
      |> render_submit()

    assert html =~ "Too many requests"
    assert DarkZenith.Accounts.get_gpg_key_info(user) == nil
  end

  test "web revocation-strategy events consume the gpg_key_mutation bucket", ctx do
    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.merge(ctx.previous, %{gpg_key_mutation: {0, 3600}})
    )

    user = user_fixture()
    pair = DarkZenith.GpgFixtures.generate_key_pair()
    {:ok, user} = DarkZenith.Accounts.upsert_gpg_key(user, pair.public, pair.private)

    {:ok, _repo} =
      DarkZenith.Repositories.create_repository(user, %{
        slug: "lv-gpg-#{System.unique_integer([:positive])}",
        name: "L",
        gpg_key_fingerprint: pair.fingerprint
      })

    {:ok, lv, _html} = build_conn() |> log_in_user(user) |> live(~p"/users/settings")

    # Opening the confirmation dialog is not the mutation; the confirming
    # click resolves to the staged event and is what the bucket governs.
    html = lv |> element("#revoke-clear-metadata") |> render_click()
    refute html =~ "Too many requests"

    html = lv |> element("#confirm_action") |> render_click()
    assert html =~ "Too many requests"

    refute DarkZenith.Repo.get!(DarkZenith.Accounts.User, user.id).gpg_key_transition_id
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
