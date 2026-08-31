defmodule DarkZenithWeb.UserLive.SettingsAccountTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "API key management" do
    test "creates a key showing the plaintext exactly once", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#create_api_key_form",
          api_key: %{"name" => "ci key", "scopes" => ["repo:read", "package:upload"]}
        )
        |> render_submit()

      assert html =~ "shown only once"
      assert [plaintext] = Regex.run(~r/dzak_[A-Za-z0-9_-]+/, html)
      assert {:ok, _} = Accounts.fetch_api_key_user(plaintext)
      assert html =~ "ci key"
      assert html =~ "package:upload, repo:read"
    end

    test "revokes a key with the signed-URL warning", %{conn: conn, user: user} do
      {:ok, {_plaintext, key}} =
        Accounts.create_api_key(user, %{name: "doomed", scopes: ["repo:read"]})

      {:ok, lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "doomed"

      confirm =
        lv |> element("#revoke-key-#{key.id}") |> render()

      assert confirm =~ "signed download URL"

      lv |> element("#revoke-key-#{key.id}") |> render_click()
      assert Accounts.list_api_keys(user) == []
    end
  end

  describe "GPG key generation" do
    test "generates a first key showing the private key exactly once", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Generate key pair"

      html =
        lv
        |> form("#generate_gpg_key_form", gpg_generation: %{"algorithm" => "ed25519"})
        |> render_submit()

      # The one-time reveal block carries the armored private key and a
      # download link, and warns it can never be shown again.
      assert html =~ "id=\"generated-gpg-private-key\""
      assert html =~ "BEGIN PGP PRIVATE KEY BLOCK"
      assert html =~ "never be shown again"
      assert html =~ "download="

      info = Accounts.get_gpg_key_info(user)
      assert html =~ info.fingerprint

      # A fresh mount no longer exposes the private key anywhere.
      {:ok, _lv, remounted} = live(build_conn() |> log_in_user(user), ~p"/users/settings")
      refute remounted =~ "PRIVATE KEY BLOCK"
    end

    test "generating over an existing key starts a replacement", %{conn: conn, user: user} do
      pair = generate_key_pair()
      {:ok, _} = Accounts.upsert_gpg_key(user, pair.public, pair.private)

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#generate_gpg_key_form", gpg_generation: %{"algorithm" => "ed25519"})
        |> render_submit()

      assert html =~ "id=\"generated-gpg-private-key\""
      assert html =~ "id=\"gpg-transition\""

      # The current key remains until the swap.
      assert DarkZenith.Repo.get!(DarkZenith.Accounts.User, user.id).gpg_key_fingerprint ==
               pair.fingerprint
    end
  end

  describe "GPG key management" do
    test "uploads, displays, and removes a real key", %{conn: conn} do
      pair = generate_key_pair()
      {:ok, lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "Upload key pair"

      lv
      |> form("#upload_gpg_key_form",
        gpg: %{"public_key" => pair.public, "private_key" => pair.private}
      )
      |> render_submit()

      html = render(lv)
      assert html =~ pair.fingerprint
      assert html =~ "never"

      lv |> element("#remove-gpg-key") |> render_click()
      assert render(lv) =~ "Upload key pair"
    end

    test "shows the expiry warning inside thirty days", %{conn: conn, user: user} do
      pair = generate_key_pair(expire: "40d")
      {:ok, _} = Accounts.upsert_gpg_key(user, pair.public, pair.private)

      # Pull the stored expiry inside the warning window.
      soon = DateTime.add(DateTime.utc_now(:second), 5, :day)

      import Ecto.Query, only: [from: 2]

      DarkZenith.Repo.update_all(
        from(u in Accounts.User, where: u.id == ^user.id),
        set: [gpg_key_expires_at: soon]
      )

      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "expires in"
    end

    test "rejects a bad pair with a helpful flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#upload_gpg_key_form", gpg: %{"public_key" => "junk", "private_key" => "junk"})
      |> render_submit()

      assert render(lv) =~ "rejected"
    end
  end
end

defmodule DarkZenithWeb.UserLive.SettingsGpgTransitionsTest do
  # Not async: overrides the signing implementation.
  use DarkZenithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.User
  alias DarkZenith.Repositories

  setup %{conn: conn} do
    Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)
    on_exit(fn -> Application.delete_env(:dark_zenith, :signing_impl) end)

    pair = generate_key_pair()
    user = user_fixture()
    {:ok, user} = Accounts.upsert_gpg_key(user, pair.public, pair.private)
    %{conn: log_in_user(conn, user), user: user, pair: pair}
  end

  test "replacing the key from settings starts the transition and shows progress", ctx do
    {:ok, _} =
      Repositories.create_repository(ctx.user, %{
        slug: "set-gpg-#{System.unique_integer([:positive])}",
        name: "S",
        gpg_key_fingerprint: ctx.pair.fingerprint
      })

    pair2 = generate_key_pair()
    {:ok, lv, html} = live(ctx.conn, ~p"/users/settings")
    assert html =~ "Replace key pair"

    lv
    |> form("#upload_gpg_key_form",
      gpg: %{"public_key" => pair2.public, "private_key" => pair2.private}
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Key replacement in progress"
    assert html =~ "id=\"gpg-transition\""

    # The current key stays displayed until the swap.
    assert html =~ ctx.pair.fingerprint
    assert DarkZenith.Repo.get!(User, ctx.user.id).gpg_key_fingerprint == ctx.pair.fingerprint
  end

  test "an in-use key offers the removal strategies", ctx do
    {:ok, _} =
      Repositories.create_repository(ctx.user, %{
        slug: "set-use-#{System.unique_integer([:positive])}",
        name: "U",
        gpg_key_fingerprint: ctx.pair.fingerprint
      })

    {:ok, lv, html} = live(ctx.conn, ~p"/users/settings")
    assert html =~ "id=\"gpg-removal-strategies\""
    assert html =~ "revoke-clear-metadata"
    refute html =~ "id=\"remove-gpg-key\""

    lv |> element("#revoke-clear-metadata") |> render_click()

    html = render(lv)
    assert html =~ "Metadata signing removal in progress"

    user = DarkZenith.Repo.get!(User, ctx.user.id)
    assert user.gpg_key_transition_id
  end

  test "RPM-signed repositories hide the clear-metadata strategy", ctx do
    {:ok, _} =
      Repositories.create_repository(ctx.user, %{
        slug: "set-rpm-#{System.unique_integer([:positive])}",
        name: "R",
        gpg_key_fingerprint: ctx.pair.fingerprint,
        sign_rpms: true
      })

    {:ok, _lv, html} = live(ctx.conn, ~p"/users/settings")
    refute html =~ "revoke-clear-metadata"
    assert html =~ "revoke-delete-packages"
  end
end
