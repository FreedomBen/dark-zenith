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
