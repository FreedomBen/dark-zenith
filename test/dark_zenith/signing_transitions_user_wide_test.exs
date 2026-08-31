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

defmodule DarkZenith.SigningTransitionsUserWideFlowsTest do
  # Not async: overrides the signing implementation.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.User
  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.SigningTransitions
  alias DarkZenith.SigningTransitions.{Item, Transition, TransitionRepository, UserWide}
  alias DarkZenith.Uploads
  alias DarkZenith.Workers.SigningItem

  setup do
    Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)
    on_exit(fn -> Application.delete_env(:dark_zenith, :signing_impl) end)

    pair = generate_key_pair()
    owner = user_fixture()
    {:ok, owner} = Accounts.upsert_gpg_key(owner, pair.public, pair.private)
    %{owner: owner, pair: pair}
  end

  defp signed_repo!(owner, pair, opts \\ []) do
    {:ok, repo} =
      Repositories.create_repository(owner, %{
        slug: "uw-#{System.unique_integer([:positive])}",
        name: "UW",
        gpg_key_fingerprint: pair.fingerprint,
        sign_rpms: Keyword.get(opts, :sign_rpms, false)
      })

    repo
  end

  defp plain_repo!(owner) do
    {:ok, repo} =
      Repositories.create_repository(owner, %{
        slug: "uw-plain-#{System.unique_integer([:positive])}",
        name: "Plain"
      })

    repo
  end

  defp run_until(transition_id, statuses, limit \\ 25) do
    Enum.reduce_while(1..limit, nil, fn _, _ ->
      :ok = UserWide.run_phase(transition_id)
      transition = Repo.get!(Transition, transition_id)

      if transition.status in statuses,
        do: {:halt, transition},
        else: {:cont, transition}
    end)
  end

  defp stub_item_pipeline(packages) do
    by_path =
      Map.new(packages, fn {package, binary} ->
        {"/dz-bucket/" <> package.storage_path, binary}
      end)

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      case {conn.method, Map.fetch(by_path, conn.request_path)} do
        {"GET", {:ok, binary}} ->
          Plug.Conn.send_resp(conn, 200, binary)

        {"PUT", _} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
          Process.put({:uploaded, conn.request_path}, byte_size(body))

          conn
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_znew")
          |> Plug.Conn.send_resp(200, "")

        {"HEAD", _} ->
          length = Process.get({:uploaded, conn.request_path}, 0)

          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(length))
          |> Plug.Conn.put_resp_header("content-type", "application/x-rpm")
          |> Plug.Conn.send_resp(200, "")

        {"DELETE", _} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end

  test "key replacement runs preparation, swap, activation, items, and completion", ctx do
    metadata_repo = signed_repo!(ctx.owner, ctx.pair)
    rpm_repo = signed_repo!(ctx.owner, ctx.pair, sign_rpms: true)
    plain = plain_repo!(ctx.owner)

    package =
      insert_package_from_rpm!(rpm_repo, minimal_binary(), %{
        storage_path: "repos/#{rpm_repo.slug}/packages/p/w1/p.rpm",
        storage_version_id: "4_zoldp"
      })

    sync_repository_metadata_state!(rpm_repo)

    pair2 = generate_key_pair()
    old_public = Repo.get!(User, ctx.owner.id).gpg_key_public

    assert {:accepted, transition} =
             UserWide.start_replacement(ctx.owner, pair2.public, pair2.private)

    assert transition.status == "preparing"
    assert transition.prepared_primary_fingerprint == pair2.fingerprint

    # Current key untouched; mutations fenced.
    user = Repo.get!(User, ctx.owner.id)
    assert user.gpg_key_fingerprint == ctx.pair.fingerprint
    assert user.gpg_key_transition_id == transition.id

    assert {:error, :gpg_key_transition_in_progress} =
             Repositories.create_repository(ctx.owner, %{slug: "nope", name: "Nope"})

    transition = run_until(transition.id, ["activating"])

    # Preparation snapshotted the two signed repositories and the package.
    snapshot_ids =
      Repo.all(
        from sr in TransitionRepository,
          where: sr.transition_id == ^transition.id,
          select: sr.repository_id
      )

    assert Enum.sort(snapshot_ids) == Enum.sort([metadata_repo.id, rpm_repo.id])
    refute plain.id in snapshot_ids

    assert [item] = SigningTransitions.list_items(transition.id)
    assert item.package_id == package.id
    assert item.expected_storage_version_id == "4_zoldp"

    # Key swap: user now carries the candidate, previous public retained,
    # candidate fields cleared.
    user = Repo.get!(User, ctx.owner.id)
    assert user.gpg_key_fingerprint == pair2.fingerprint
    assert user.previous_gpg_key_public == old_public
    assert is_nil(Repo.get!(Transition, transition.id).prepared_gpg_key_private)

    transition = run_until(transition.id, ["active"])

    # Activation applied both repository rows with the new fingerprint.
    for repo_id <- [metadata_repo.id, rpm_repo.id] do
      assert Repo.get!(Repository, repo_id).gpg_key_fingerprint == pair2.fingerprint
    end

    assert Repo.all(
             from sr in TransitionRepository,
               where: sr.transition_id == ^transition.id,
               select: sr.application_status
           )
           |> Enum.all?(&(&1 == "applied"))

    # Mutations admitted again while items re-sign.
    assert {:ok, _} = Repositories.create_repository(ctx.owner, %{slug: "mid", name: "Mid"})

    stub_item_pipeline([{package, minimal_binary()}])
    [item] = SigningTransitions.list_items(transition.id)
    assert :ok = perform_job(SigningItem, %{"item_id" => item.id})
    assert Repo.get!(Item, item.id).status == "succeeded"

    # Completion needs every affected cache current.
    assert SigningTransitions.check_completion(transition.id) == :not_yet
    Oban.drain_queue(queue: :metadata, with_safety: false)

    assert SigningTransitions.check_completion(transition.id) == :completed

    user = Repo.get!(User, ctx.owner.id)
    assert is_nil(user.previous_gpg_key_public)
    assert is_nil(user.gpg_key_transition_id)
    assert Repo.get!(Transition, transition.id).status == "completed"
  end

  test "replacement is refused while a repository is mid enable transition", ctx do
    repo = signed_repo!(ctx.owner, ctx.pair)

    {1, _} =
      Repo.update_all(
        from(r in Repository, where: r.id == ^repo.id),
        set: [sign_rpms: true, rpm_signing_state: "signing"]
      )

    pair2 = generate_key_pair()

    assert {:error, :transition_in_progress} =
             UserWide.start_replacement(ctx.owner, pair2.public, pair2.private)
  end

  test "clear_metadata_signing clears repositories and removes the key", ctx do
    repo_a = signed_repo!(ctx.owner, ctx.pair)
    repo_b = signed_repo!(ctx.owner, ctx.pair)
    plain = plain_repo!(ctx.owner)

    assert {:accepted, transition} = UserWide.start_removal(ctx.owner, "clear_metadata_signing")
    assert transition.status == "preparing"

    transition = run_until(transition.id, ["completed"])
    assert transition.status == "completed"
    assert transition.completed_at

    for repo_id <- [repo_a.id, repo_b.id] do
      repo = Repo.get!(Repository, repo_id)
      assert is_nil(repo.gpg_key_fingerprint)
      assert repo.metadata_revision > 0
    end

    assert Repo.get!(Repository, plain.id).metadata_revision == 0

    user = Repo.get!(User, ctx.owner.id)
    assert is_nil(user.gpg_key_fingerprint)
    assert is_nil(user.gpg_key_private)
    assert is_nil(user.gpg_key_transition_id)
  end

  test "clear_metadata_signing is refused while any repository signs RPMs", ctx do
    signed_repo!(ctx.owner, ctx.pair, sign_rpms: true)
    assert {:error, :in_use} = UserWide.start_removal(ctx.owner, "clear_metadata_signing")
  end

  test "delete_signed_packages deletes packages via items then disables signing", ctx do
    rpm_repo = signed_repo!(ctx.owner, ctx.pair, sign_rpms: true)
    metadata_repo = signed_repo!(ctx.owner, ctx.pair)

    p1 =
      insert_package_from_rpm!(rpm_repo, minimal_binary(), %{
        storage_path: "repos/#{rpm_repo.slug}/packages/p1/w1/p1.rpm",
        storage_version_id: "4_zp1"
      })

    p2 =
      insert_package_from_rpm!(rpm_repo, v4_binary(), %{
        storage_path: "repos/#{rpm_repo.slug}/packages/p2/w1/p2.rpm",
        storage_version_id: "4_zp2"
      })

    sync_repository_metadata_state!(rpm_repo)
    stored = Repo.get!(User, ctx.owner.id).storage_bytes
    assert stored > 0

    assert {:accepted, transition} = UserWide.start_removal(ctx.owner, "delete_signed_packages")

    transition = run_until(transition.id, ["active"])

    items = SigningTransitions.list_items(transition.id)
    assert length(items) == 2

    # Creations fenced; explicit deletion admitted.
    assert {:error, :gpg_key_transition_in_progress} =
             Uploads.create_intent(ctx.owner, rpm_repo, %{
               mode: "api",
               filename: "x.rpm",
               size: 10
             })

    for item <- items do
      assert :ok = perform_job(SigningItem, %{"item_id" => item.id})
    end

    refute Repo.get(DarkZenith.Packages.Package, p1.id)
    refute Repo.get(DarkZenith.Packages.Package, p2.id)
    assert Repo.get!(User, ctx.owner.id).storage_bytes == 0

    repo = Repo.get!(Repository, rpm_repo.id)
    assert repo.package_count == 0

    transition = run_until(transition.id, ["completed"])
    assert transition.status == "completed"

    repo = Repo.get!(Repository, rpm_repo.id)
    refute repo.sign_rpms
    assert repo.rpm_signing_state == "disabled"
    assert is_nil(repo.gpg_key_fingerprint)
    assert is_nil(Repo.get!(Repository, metadata_repo.id).gpg_key_fingerprint)

    user = Repo.get!(User, ctx.owner.id)
    assert is_nil(user.gpg_key_fingerprint)
    assert is_nil(user.gpg_key_transition_id)

    # The fence lifted with the final commit.
    assert {:ok, _} = Repositories.create_repository(ctx.owner, %{slug: "after", name: "After"})
  end

  test "a removal strategy supersedes an unresolved replacement", ctx do
    signed_repo!(ctx.owner, ctx.pair)
    pair2 = generate_key_pair()

    assert {:accepted, replacement} =
             UserWide.start_replacement(ctx.owner, pair2.public, pair2.private)

    assert {:accepted, removal} = UserWide.start_removal(ctx.owner, "clear_metadata_signing")

    replacement = Repo.get!(Transition, replacement.id)
    assert replacement.status == "canceled"
    assert is_nil(replacement.prepared_gpg_key_private)

    assert Repo.get!(User, ctx.owner.id).gpg_key_transition_id == removal.id
  end
end
