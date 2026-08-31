defmodule DarkZenithWeb.AdminLiveTest do
  use DarkZenithWeb.ConnCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import Ecto.Query, only: [from: 2]

  alias DarkZenith.Accounts

  setup %{conn: conn} do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "non-admins get the standard 404", %{admin: _admin} do
    user = user_fixture()

    assert_error_sent 404, fn ->
      build_conn() |> log_in_user(user) |> get(~p"/admin/users")
    end
  end

  describe "user management" do
    test "creates an auto-confirmed user without confirmation mail", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> form("#admin_create_user_form",
        user: %{"email" => "provisioned@example.com", "password" => valid_user_password()}
      )
      |> render_submit()

      user = Accounts.get_user_by_email("provisioned@example.com")
      assert user.confirmed_at
      assert {:ok, _} = Accounts.authenticate_user(user.email, valid_user_password())

      refute_enqueued(
        worker: DarkZenith.Workers.EmailDelivery,
        args: %{to: "provisioned@example.com"}
      )

      assert Enum.any?(DarkZenith.Audit.list_events(), &(&1.action == "admin.user_create"))
    end

    test "provisioning converts pending invitations", %{conn: conn, admin: _admin} do
      owner = user_fixture()
      repo = repository_fixture(owner)
      email = "invited-#{System.unique_integer([:positive])}@example.com"
      {:ok, :created, _} = DarkZenith.Collaborators.add_collaborator(owner, repo, email)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> form("#admin_create_user_form",
        user: %{"email" => email, "password" => valid_user_password()}
      )
      |> render_submit()

      user = Accounts.get_user_by_email(email)

      assert DarkZenith.Repo.get_by(DarkZenith.Collaborators.Collaborator,
               repository_id: repo.id,
               user_id: user.id
             )
    end

    test "grants and revokes the admin flag on other users", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("#grant-admin-#{user.id}") |> render_click()
      assert DarkZenith.Repo.get!(Accounts.User, user.id).is_admin

      lv |> element("#revoke-admin-#{user.id}") |> render_click()
      refute DarkZenith.Repo.get!(Accounts.User, user.id).is_admin
    end

    test "deletion is rejected while the target owns repositories", %{conn: conn} do
      owner = user_fixture()
      repository_fixture(owner)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      lv |> element("#delete-user-#{owner.id}") |> render_click()

      assert render(lv) =~ "still owns repositories"
      assert DarkZenith.Repo.get(Accounts.User, owner.id)
    end

    test "deletes a user, cleaning intents and addressed invitations", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner)
      doomed = user_fixture()

      # Invitation addressed to the doomed user's email on another repo.
      {:ok, :created, _} = DarkZenith.Collaborators.add_collaborator(owner, repo, doomed.email)
      # An intent the doomed user initiated as an admin? They are not a
      # manager; give them their own upload on the owner's repo via admin.
      admin2 = admin_fixture()

      {:ok, intent, _} =
        DarkZenith.Uploads.create_intent(admin2, repo, %{
          filename: "x.rpm",
          size: 10,
          mode: "api"
        })

      # Re-own the intent to the doomed user for the cleanup assertion.
      DarkZenith.Repo.update_all(
        from(i in DarkZenith.Uploads.Intent, where: i.id == ^intent.id),
        set: [user_id: doomed.id]
      )

      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      lv |> element("#delete-user-#{doomed.id}") |> render_click()

      refute DarkZenith.Repo.get(Accounts.User, doomed.id)
      refute DarkZenith.Repo.get(DarkZenith.Uploads.Intent, intent.id)
      refute DarkZenith.Repo.get(DarkZenith.Storage.Reservation, intent.reservation_id)

      assert_enqueued(
        worker: DarkZenith.Workers.StagingCleanup,
        args: %{staging_path: intent.staging_path}
      )

      # The collaborator row created from the earlier invitation is gone,
      # and the invitation cannot re-attach later.
      refute DarkZenith.Repo.get_by(DarkZenith.Collaborators.Invitation, email: doomed.email)
    end
  end

  describe "audit, slugs, and jobs pages" do
    test "the audit browser filters by action prefix", %{conn: conn} do
      user_fixture()
      {:ok, lv, html} = live(conn, ~p"/admin/audit")
      assert html =~ "auth.register"

      html = lv |> render_change("filter", %{"action" => "repository.", "actor_email" => ""})
      refute html =~ "auth.register"
    end

    test "retired slugs can be released", %{conn: conn} do
      owner = user_fixture()
      repo = repository_fixture(owner)
      slug = repo.slug
      :ok = DarkZenith.Repositories.delete_repository(owner, repo)

      {:ok, lv, html} = live(conn, ~p"/admin/slugs")
      assert html =~ slug

      lv |> element("#release-#{slug}") |> render_click()

      refute DarkZenith.Repo.get_by(DarkZenith.Repositories.SlugReservation, slug: slug)
    end

    test "failed jobs are listed with retry", %{conn: conn} do
      job =
        DarkZenith.Repo.insert!(%Oban.Job{
          worker: "Broken.Worker",
          queue: "default",
          args: %{},
          state: "discarded",
          attempt: 20,
          max_attempts: 20,
          errors: [%{"error" => "boom"}]
        })

      {:ok, lv, html} = live(conn, ~p"/admin/jobs")
      assert html =~ "Broken.Worker"
      assert html =~ "boom"

      lv |> element("#retry-job-#{job.id}") |> render_click()
      assert DarkZenith.Repo.get!(Oban.Job, job.id).state in ["available", "scheduled"]
    end
  end
end

defmodule DarkZenithWeb.AdminTransitionsLiveTest do
  use DarkZenithWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo
  alias DarkZenith.SigningTransitions.{Item, Transition}
  alias DarkZenith.Workers.SigningPhase

  setup %{conn: conn} do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp failed_user_wide!(owner, attrs \\ %{}) do
    transition =
      Repo.insert!(
        struct!(
          %Transition{
            kind: "replace_gpg_key",
            user_id: owner.id,
            status: "failed",
            resume_status: "preparing",
            last_error_code: "database_unavailable",
            phase_attempts: 20
          },
          attrs
        )
      )

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^owner.id),
        set: [gpg_key_transition_id: transition.id]
      )

    transition
  end

  test "lists transitions with phase state and resets a failed phase", ctx do
    owner = user_fixture()
    transition = failed_user_wide!(owner)

    {:ok, lv, html} = live(ctx.conn, ~p"/admin/transitions")
    assert html =~ "replace_gpg_key"
    assert html =~ "database_unavailable"

    lv |> element("#reset-phase-#{transition.id}") |> render_click()

    reset = Repo.get!(Transition, transition.id)
    assert reset.status == "preparing"
    assert reset.phase_attempts == 0
    assert reset.resume_status == nil
    assert reset.phase_next_attempt_at

    worker_name = Oban.Worker.to_string(SigningPhase)

    assert Repo.exists?(
             from(j in Oban.Job,
               where: j.worker == ^worker_name and j.state in ["available", "scheduled"]
             )
           )
  end

  test "cancel clears a pre-swap replacement but refuses a post-swap one", ctx do
    owner = user_fixture()
    pre = failed_user_wide!(owner)

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/transitions")
    lv |> element("#cancel-#{pre.id}") |> render_click()

    assert Repo.get!(Transition, pre.id).status == "canceled"
    assert Repo.get!(User, owner.id).gpg_key_transition_id == nil

    owner2 = user_fixture()

    post =
      failed_user_wide!(owner2, %{
        resume_status: "activating",
        last_error_code: "storage_unavailable"
      })

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/transitions")
    html = lv |> element("#cancel-#{post.id}") |> render_click()

    assert html =~ "cannot be canceled"
    assert Repo.get!(Transition, post.id).status == "failed"
    assert Repo.get!(User, owner2.id).gpg_key_transition_id == post.id
  end

  test "inspect shows items and resets the failed ones", ctx do
    owner = user_fixture()

    transition =
      failed_user_wide!(owner, %{
        kind: "delete_signed_packages",
        resume_status: "active"
      })

    now = DateTime.utc_now(:second)

    item =
      Repo.insert!(%Item{
        transition_id: transition.id,
        repository_id: Ecto.UUID.generate(),
        package_id: Ecto.UUID.generate(),
        expected_storage_path: "repos/x/packages/p/w/x.rpm",
        expected_storage_version_id: "4_zx",
        status: "failed",
        attempts: 20,
        last_error_code: "storage_unavailable",
        completed_at: now
      })

    {:ok, lv, _html} = live(ctx.conn, ~p"/admin/transitions")
    html = lv |> element("#inspect-#{transition.id}") |> render_click()
    assert html =~ "1 failed"
    assert html =~ item.package_id

    lv |> element("#reset-failed-items") |> render_click()

    reset = Repo.get!(Item, item.id)
    assert reset.status == "pending"
    assert reset.attempts == 0

    # No failed items remain, so the transition resumes active.
    assert Repo.get!(Transition, transition.id).status == "active"
  end
end
