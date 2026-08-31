defmodule DarkZenithWeb.RepositoryLiveTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Repositories

  describe "repository index" do
    test "anonymous visitors see public repositories only", %{conn: conn} do
      owner = user_fixture()
      public = repository_fixture(owner, %{name: "Public Repo", is_public: true})
      _private = repository_fixture(owner, %{name: "Private Repo", is_public: false})

      {:ok, _lv, html} = live(conn, ~p"/repos")

      assert html =~ "Public Repo"
      refute html =~ "Private Repo"
      refute html =~ "Create New Repo"
      assert html =~ public.slug
    end

    test "authenticated users see their private repositories and the create action", %{
      conn: conn
    } do
      owner = user_fixture()
      repository_fixture(owner, %{name: "My Private", is_public: false})

      {:ok, _lv, html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos")

      assert html =~ "My Private"
      assert html =~ "Create New Repo"

      # visibility renders as the semantic badge (docs/DESIGN_UI.md — Badges)
      assert html =~ "hero-lock-closed-micro"
      assert html =~ "Private"
    end

    test "an empty index renders the reticle empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/repos")

      assert html =~ "No repositories yet."
      assert html =~ "opacity-30"
    end
  end

  describe "repository creation" do
    test "requires authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/repos/new")
    end

    test "creates a repository and navigates to it", %{conn: conn} do
      owner = user_fixture()
      conn = log_in_user(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/repos/new")

      lv
      |> form("#repository_form",
        repository: %{slug: "web-created", name: "Web Created", is_public: "true"}
      )
      |> render_submit()

      assert_redirect(lv, "/repos/web-created")
      assert Repositories.get_repository_by_slug("web-created")
    end

    test "shows validation errors", %{conn: conn} do
      owner = user_fixture()
      conn = log_in_user(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/repos/new")

      html =
        lv
        |> form("#repository_form", repository: %{slug: "Bad Slug!", name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "repository detail" do
    test "renders a public repository with setup instructions", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{name: "Shown", is_public: true})

      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}")

      assert html =~ "Shown"
      assert html =~ "[dark-zenith-#{repo.slug}]"
      assert html =~ "dnf config-manager --add-repo"
      assert html =~ "dnf5 config-manager addrepo"
      assert html =~ "No packages yet"
      refute html =~ "Settings"

      # setup snippets are command blocks with copy buttons (docs/DESIGN_UI.md)
      assert html =~ ~s(aria-label="Copy to clipboard")
      assert html =~ "bg-umbra"

      # commands render flush inside <pre><code>: no template indentation to
      # display or copy
      assert html =~ "<code>dnf config-manager --add-repo"
      assert html =~ "<code>dnf5 config-manager addrepo"
    end

    test "owners see management actions", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: true})

      {:ok, _lv, html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}")

      assert html =~ "Settings"
      assert html =~ "Upload RPM"
    end

    test "private repositories show credentialed instructions without config-manager", %{
      conn: conn
    } do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})

      {:ok, _lv, html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}")

      assert html =~ "username=token"
      assert html =~ "password=&lt;api-key&gt;"
      assert html =~ "chmod 600"
      refute html =~ "config-manager --add-repo"
    end

    test "private repositories prompt for API-key creation only without a suitable key", %{
      conn: conn
    } do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      conn = log_in_user(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}")
      assert html =~ "no active API key with"
      assert html =~ "/users/settings"

      {:ok, _} =
        DarkZenith.Accounts.create_api_key(owner, %{name: "reader", scopes: ["repo:read"]})

      {:ok, _lv, html} = live(conn, ~p"/repos/#{repo.slug}")
      refute html =~ "no active API key with"
    end

    test "a key without repo:read still prompts on a private repository", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})

      {:ok, _} =
        DarkZenith.Accounts.create_api_key(owner, %{name: "up", scopes: ["package:upload"]})

      {:ok, _lv, html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}")

      assert html =~ "no active API key with"
    end

    test "GPG import instructions are authenticated for private repositories", %{conn: conn} do
      pair = DarkZenith.GpgFixtures.generate_key_pair()
      owner = user_fixture()
      {:ok, owner} = DarkZenith.Accounts.upsert_gpg_key(owner, pair.public, pair.private)

      {:ok, private_repo} =
        DarkZenith.Repositories.create_repository(owner, %{
          slug: "priv-key-#{System.unique_integer([:positive])}",
          name: "Private keyed",
          is_public: false,
          gpg_key_fingerprint: pair.fingerprint
        })

      conn = log_in_user(conn, owner)
      {:ok, _lv, html} = live(conn, ~p"/repos/#{private_repo.slug}")

      # The interactive authenticated import step: curl prompts for the API
      # key; credentials never appear in a URL or command argument.
      assert html =~ "curl --fail --user token"
      assert html =~ "rpmkeys --import -"
      refute html =~ ~r/rpmkeys --import http/

      {:ok, public_repo} =
        DarkZenith.Repositories.create_repository(owner, %{
          slug: "pub-key-#{System.unique_integer([:positive])}",
          name: "Public keyed",
          is_public: true,
          gpg_key_fingerprint: pair.fingerprint
        })

      {:ok, _lv, html} = live(conn, ~p"/repos/#{public_repo.slug}")
      assert html =~ "sudo rpmkeys --import http"
      refute html =~ "curl --fail"
    end

    test "anonymous requests for private or unknown slugs redirect to login", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/repos/#{repo.slug}")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/repos/missing-slug")
    end

    test "authenticated users without access get the standard 404", %{conn: conn} do
      owner = user_fixture()
      stranger = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})

      conn = log_in_user(conn, stranger)

      assert_error_sent 404, fn ->
        get(conn, ~p"/repos/#{repo.slug}")
      end
    end

    test "collaborators can view a private repository but see no management actions", %{
      conn: conn
    } do
      owner = user_fixture()
      collaborator = user_fixture()
      repo = repository_fixture(owner, %{name: "Shared Repo", is_public: false})
      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(repo, collaborator)

      {:ok, _lv, html} =
        conn
        |> log_in_user(collaborator)
        |> live(~p"/repos/#{repo.slug}")

      assert html =~ "Shared Repo"
      refute html =~ "/repos/#{repo.slug}/settings"
      refute html =~ "Upload RPM"

      # A collaborator's visible private repository also appears in the index.
      {:ok, _lv, index_html} =
        build_conn()
        |> log_in_user(collaborator)
        |> live(~p"/repos")

      assert index_html =~ "Shared Repo"
    end
  end

  describe "repository settings" do
    test "owners update settings", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{name: "Before"})

      {:ok, lv, _html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}/settings")

      lv
      |> form("#repository_settings_form", repository: %{name: "After", is_public: "true"})
      |> render_submit()

      updated = Repositories.get_repository_by_slug(repo.slug)
      assert updated.name == "After"
      assert updated.is_public
    end

    test "non-owners get the standard 404", %{conn: conn} do
      owner = user_fixture()
      stranger = user_fixture()
      repo = repository_fixture(owner, %{is_public: true})

      conn = log_in_user(conn, stranger)

      assert_error_sent 404, fn ->
        get(conn, ~p"/repos/#{repo.slug}/settings")
      end
    end

    test "owners can delete the repository after typing the slug to confirm", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner)

      {:ok, lv, _html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}/settings")

      # opening the dialog does not delete anything
      html = lv |> element("#delete_repository") |> render_click()
      assert html =~ "delete_repository_modal"
      assert Repositories.get_repository_by_slug(repo.slug)

      # the destructive button stays disabled until the exact slug is typed
      assert lv |> element("#confirm_delete_repository") |> render() =~ "disabled"

      html =
        lv
        |> element("#delete_repository_modal form")
        |> render_change(%{"confirmation" => "not-the-slug"})

      assert html =~ "disabled"
      assert Repositories.get_repository_by_slug(repo.slug)

      lv
      |> element("#delete_repository_modal form")
      |> render_change(%{"confirmation" => repo.slug})

      refute lv |> element("#confirm_delete_repository") |> render() =~ "disabled"

      lv |> element("#delete_repository_modal form") |> render_submit()

      assert_redirect(lv, "/repos")
      refute Repositories.get_repository_by_slug(repo.slug)
    end

    test "the delete event is refused server-side without the typed confirmation", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner)

      {:ok, lv, _html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}/settings")

      lv |> element("#delete_repository") |> render_click()

      # submitting the form (e.g. Enter in the input) with a mismatch is a no-op
      lv
      |> element("#delete_repository_modal form")
      |> render_change(%{"confirmation" => "wrong"})

      lv |> element("#delete_repository_modal form") |> render_submit()

      assert Repositories.get_repository_by_slug(repo.slug)

      # so is pushing the event directly, bypassing the form
      render_click(lv, "delete", %{})
      assert Repositories.get_repository_by_slug(repo.slug)
    end

    test "cancel closes the delete dialog without deleting", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner)

      {:ok, lv, _html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}/settings")

      lv |> element("#delete_repository") |> render_click()
      html = render_click(lv, "cancel_delete", %{})

      refute html =~ "delete_repository_modal"
      assert Repositories.get_repository_by_slug(repo.slug)
    end
  end

  describe "collaborator management" do
    alias DarkZenith.Collaborators

    defp settings_lv(conn, owner, repo) do
      {:ok, lv, html} =
        conn
        |> log_in_user(owner)
        |> live(~p"/repos/#{repo.slug}/settings")

      {lv, html}
    end

    test "owners add registered users and unregistered emails", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      user = user_fixture()
      {lv, html} = settings_lv(conn, owner, repo)

      assert html =~ "Manage Collaborators"

      lv
      |> form("#add_collaborator_form", collaborator: %{email: user.email})
      |> render_submit()

      html = render(lv)
      assert html =~ user.email
      assert html =~ "queued"

      invited = "pending#{System.unique_integer([:positive])}@example.com"

      lv
      |> form("#add_collaborator_form", collaborator: %{email: invited})
      |> render_submit()

      html = render(lv)
      assert html =~ invited
      assert html =~ "invitation"
      # Invitations display their expiration.
      assert html =~ "Expires"
    end

    test "adding the owner's email shows a validation error", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      {lv, _html} = settings_lv(conn, owner, repo)

      html =
        lv
        |> form("#add_collaborator_form", collaborator: %{email: owner.email})
        |> render_submit()

      assert html =~ "cannot invite the repository owner"
    end

    test "idempotent adds surface the existing row instead of duplicating", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      user = user_fixture()
      {:ok, :created, _} = Collaborators.add_collaborator(owner, repo, user.email)
      {lv, _html} = settings_lv(conn, owner, repo)

      lv
      |> form("#add_collaborator_form", collaborator: %{email: user.email})
      |> render_submit()

      assert render(lv) =~ "already"
      assert length(Collaborators.list_rows(repo)) == 1
    end

    test "public repositories list and remove rows but disable adding", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      user = user_fixture()
      {:ok, :created, collaborator} = Collaborators.add_collaborator(owner, repo, user.email)
      {:ok, repo} = Repositories.update_repository(owner, repo, %{"is_public" => true})

      {lv, html} = settings_lv(conn, owner, repo)

      assert html =~ user.email
      assert html =~ "Make the repository private to add collaborators"
      refute has_element?(lv, "#add_collaborator_form")

      lv |> element("#remove-collaborator-#{collaborator.id}") |> render_click()
      assert Collaborators.list_rows(repo) == []
    end

    test "removal warns about outstanding signed URLs and cancellation works", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner, %{is_public: false})
      user = user_fixture()
      {:ok, :created, collaborator} = Collaborators.add_collaborator(owner, repo, user.email)

      {:ok, :created, invitation} =
        Collaborators.add_collaborator(
          owner,
          repo,
          "pending#{System.unique_integer([:positive])}@example.com"
        )

      {lv, html} = settings_lv(conn, owner, repo)

      assert html =~ "signed lifetime"

      lv |> element("#remove-collaborator-#{collaborator.id}") |> render_click()
      lv |> element("#cancel-invitation-#{invitation.id}") |> render_click()

      assert Collaborators.list_rows(repo) == []
    end
  end
end
