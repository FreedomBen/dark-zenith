defmodule DarkZenith.SigningTransitionsUserWideTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts.User
  alias DarkZenith.Packages
  alias DarkZenith.Repo
  alias DarkZenith.Repositories
  alias DarkZenith.SigningTransitions
  alias DarkZenith.SigningTransitions.Transition
  alias DarkZenith.Uploads

  defp attach_transition!(user, attrs) do
    transition =
      Repo.insert!(
        struct!(
          %Transition{user_id: user.id, phase_attempts: 0},
          Map.merge(%{status: "preparing"}, Map.new(attrs))
        )
      )

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(u in User, where: u.id == ^user.id),
        set: [gpg_key_transition_id: transition.id]
      )

    transition
  end

  describe "user_fence/1" do
    test "no transition means no fence" do
      user = user_fixture()
      assert SigningTransitions.user_fence(user.id) == nil
    end

    test "replacement blocks everything while preparing and activating, nothing while active" do
      for {status, resume, expected} <- [
            {"preparing", nil, :all},
            {"activating", nil, :all},
            {"failed", "preparing", :all},
            {"failed", "activating", :all},
            {"active", nil, nil},
            {"failed", "active", nil}
          ] do
        user = user_fixture()

        attach_transition!(user, %{
          kind: "replace_gpg_key",
          status: status,
          resume_status: resume,
          last_error_code: if(status == "failed", do: "signing_unavailable"),
          phase_next_attempt_at:
            if(status in ["preparing", "activating"], do: DateTime.utc_now(:second))
        })

        fence = SigningTransitions.user_fence(user.id)

        case expected do
          nil -> assert fence == nil, "#{status}/#{resume}"
          scope -> assert fence.scope == scope, "#{status}/#{resume}"
        end
      end
    end

    test "removal kinds block creations in every unresolved phase and deletions only while preparing" do
      for kind <- ["clear_metadata_signing", "delete_signed_packages"],
          {status, resume, expected} <- [
            {"preparing", nil, :all},
            {"failed", "preparing", :all},
            {"active", nil, :creations},
            {"finalizing", nil, :creations},
            {"failed", "active", :creations},
            {"failed", "finalizing", :creations}
          ] do
        user = user_fixture()

        attach_transition!(user, %{
          kind: kind,
          status: status,
          resume_status: resume,
          last_error_code: if(status == "failed", do: "signing_unavailable"),
          phase_next_attempt_at:
            if(status in ["preparing", "finalizing"], do: DateTime.utc_now(:second))
        })

        assert SigningTransitions.user_fence(user.id).scope == expected,
               "#{kind} #{status}/#{resume}"
      end
    end
  end

  describe "owner mutation guards" do
    setup do
      owner = user_fixture()
      repo = repository_fixture(owner)
      %{owner: owner, repo: repo}
    end

    test "repository creation is rejected during a blocking phase", %{owner: owner} do
      attach_transition!(owner, %{
        kind: "replace_gpg_key",
        status: "preparing",
        phase_next_attempt_at: DateTime.utc_now(:second)
      })

      assert {:error, :gpg_key_transition_in_progress} =
               Repositories.create_repository(owner, %{slug: "fenced", name: "Fenced"})
    end

    test "repository creation stays open during replacement active", %{owner: owner} do
      attach_transition!(owner, %{kind: "replace_gpg_key", status: "active"})

      assert {:ok, _} = Repositories.create_repository(owner, %{slug: "open-repo", name: "Open"})
    end

    test "signing-setting changes are rejected while a removal transition is finalizing",
         %{owner: owner, repo: repo} do
      {1, _} =
        Repo.update_all(
          Ecto.Query.from(r in Repositories.Repository, where: r.id == ^repo.id),
          set: [sign_rpms: true, rpm_signing_state: "enabled", gpg_key_fingerprint: String.duplicate("A", 40)]
        )

      repo = Repo.get!(Repositories.Repository, repo.id)

      attach_transition!(owner, %{
        kind: "clear_metadata_signing",
        status: "finalizing",
        phase_next_attempt_at: DateTime.utc_now(:second)
      })

      assert {:error, :gpg_key_transition_in_progress} =
               Repositories.update_repository(owner, repo, %{sign_rpms: false})

      # Non-signing settings stay editable.
      assert {:ok, _} = Repositories.update_repository(owner, repo, %{name: "Renamed"})
    end

    test "repository deletion is rejected while preparing but allowed while a removal is active",
         %{owner: owner, repo: repo} do
      transition =
        attach_transition!(owner, %{
          kind: "delete_signed_packages",
          status: "preparing",
          phase_next_attempt_at: DateTime.utc_now(:second)
        })

      assert {:error, :gpg_key_transition_in_progress} =
               Repositories.delete_repository(owner, repo)

      {1, _} =
        Repo.update_all(
          Ecto.Query.from(t in Transition, where: t.id == ^transition.id),
          set: [status: "active", phase_next_attempt_at: nil]
        )

      assert :ok = Repositories.delete_repository(owner, repo)
    end

    test "repository deletion marks the transition's snapshot row satisfied",
         %{owner: owner, repo: repo} do
      transition = attach_transition!(owner, %{kind: "delete_signed_packages", status: "active"})

      row =
        Repo.insert!(%SigningTransitions.TransitionRepository{
          transition_id: transition.id,
          repository_id: repo.id
        })

      assert :ok = Repositories.delete_repository(owner, repo)

      row = Repo.get!(SigningTransitions.TransitionRepository, row.id)
      assert row.application_status == "satisfied_deleted"
      assert row.applied_at
    end

    test "package deletion is fenced the same way", %{owner: owner, repo: repo} do
      package = insert_package_from_rpm!(repo, minimal_binary())
      sync_repository_metadata_state!(repo)

      attach_transition!(owner, %{
        kind: "replace_gpg_key",
        status: "preparing",
        phase_next_attempt_at: DateTime.utc_now(:second)
      })

      assert {:error, :gpg_key_transition_in_progress} =
               Packages.delete_package(owner, repo, package)
    end

    test "upload intent creation is rejected during any blocking-creation phase",
         %{owner: owner, repo: repo} do
      attach_transition!(owner, %{kind: "delete_signed_packages", status: "active"})

      assert {:error, :gpg_key_transition_in_progress} =
               Uploads.create_intent(owner, repo, %{
                 mode: "api",
                 filename: "a.rpm",
                 size: 100
               })
    end
  end
end

defmodule DarkZenith.SigningTransitionsFenceDeferralTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.B2StubHelpers
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Repo
  alias DarkZenith.SigningTransitions.Transition
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.UploadProcessing

  test "a queued upload worker claim defers under the owner fence without consuming budget" do
    owner = user_fixture()
    repo = repository_fixture(owner)
    binary = minimal_binary()

    {:ok, intent, _} =
      Uploads.create_intent(owner, repo, %{
        filename: "a.rpm",
        size: byte_size(binary),
        mode: "api"
      })

    stub_pipeline(intent, binary)
    {:ok, queued} = Uploads.complete_intent(owner, intent, 1, "4_zstaged")
    attempts_before = queued.attempts

    transition =
      Repo.insert!(%Transition{
        kind: "replace_gpg_key",
        user_id: owner.id,
        status: "preparing",
        phase_next_attempt_at: DateTime.utc_now(:second)
      })

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(u in DarkZenith.Accounts.User, where: u.id == ^owner.id),
        set: [gpg_key_transition_id: transition.id]
      )

    assert :ok = perform_job(UploadProcessing, %{"intent_id" => queued.id})

    after_run = Repo.get!(Intent, queued.id)
    assert after_run.status == "queued"
    assert after_run.attempts == attempts_before
    assert DateTime.compare(after_run.next_attempt_at, DateTime.utc_now()) == :gt
  end
end
