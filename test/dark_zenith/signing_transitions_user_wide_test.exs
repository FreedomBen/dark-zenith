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
    attrs = Map.merge(%{status: "preparing"}, Map.new(attrs))

    # A pre-swap replacement row must carry the prepared candidate fields to
    # satisfy the signing_transitions_prepared_candidate check.
    attrs =
      if Map.get(attrs, :kind) == "replace_gpg_key" and
           (attrs.status == "preparing" or
              (attrs.status == "failed" and Map.get(attrs, :resume_status) == "preparing")) do
        Map.merge(
          %{
            prepared_gpg_key_private: "prepared-private-envelope",
            prepared_gpg_key_public: "prepared-public",
            prepared_primary_fingerprint: String.duplicate("A", 40),
            prepared_signing_fingerprint: String.duplicate("B", 40)
          },
          attrs
        )
      else
        attrs
      end

    transition =
      Repo.insert!(struct!(%Transition{user_id: user.id, phase_attempts: 0}, attrs))

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
          set: [
            sign_rpms: true,
            rpm_signing_state: "enabled",
            gpg_key_fingerprint: String.duplicate("A", 40)
          ]
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
        phase_next_attempt_at: DateTime.utc_now(:second),
        prepared_gpg_key_private: "prepared-private-envelope",
        prepared_gpg_key_public: "prepared-public",
        prepared_primary_fingerprint: String.duplicate("A", 40),
        prepared_signing_fingerprint: String.duplicate("B", 40)
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

defmodule DarkZenith.SigningTransitionsUserWideFaultTest do
  # Not async: overrides batch size and the signing implementation.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Repositories
  alias DarkZenith.SigningTransitions.{Item, Transition, TransitionRepository, UserWide}
  alias DarkZenith.Workers.RetryPolicy

  setup do
    Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)
    Application.put_env(:dark_zenith, :signing_preparation_batch_size, 1)

    on_exit(fn ->
      Application.delete_env(:dark_zenith, :signing_impl)
      Application.delete_env(:dark_zenith, :signing_preparation_batch_size)
    end)

    pair = generate_key_pair()
    owner = user_fixture()
    {:ok, owner} = Accounts.upsert_gpg_key(owner, pair.public, pair.private)
    %{owner: owner, pair: pair}
  end

  test "preparation advances one durable batch at a time with idempotent re-runs", ctx do
    for _ <- 1..3 do
      {:ok, _} =
        Repositories.create_repository(ctx.owner, %{
          slug: "fault-#{System.unique_integer([:positive])}",
          name: "F",
          gpg_key_fingerprint: ctx.pair.fingerprint
        })
    end

    assert {:accepted, transition} = UserWide.start_removal(ctx.owner, "clear_metadata_signing")

    # One batch per run: after two runs exactly two snapshot rows exist and
    # the cursor sits at the second row.
    :ok = UserWide.run_phase(transition.id)
    :ok = UserWide.run_phase(transition.id)

    rows =
      Repo.all(
        from sr in TransitionRepository,
          where: sr.transition_id == ^transition.id,
          order_by: [asc: sr.repository_id],
          select: sr.repository_id
      )

    assert length(rows) == 2

    current = Repo.get!(Transition, transition.id)
    assert current.repositories_prepared_through == Enum.at(rows, 1)
    refute current.repositories_preparation_complete

    # Replaying the same batch after a simulated crash is idempotent: the
    # unique upsert cannot duplicate rows.
    {1, _} =
      Repo.update_all(
        from(t in Transition, where: t.id == ^transition.id),
        set: [repositories_prepared_through: Enum.at(rows, 0)]
      )

    :ok = UserWide.run_phase(transition.id)

    count =
      Repo.aggregate(
        from(sr in TransitionRepository, where: sr.transition_id == ^transition.id),
        :count
      )

    assert count == 2
  end

  test "transient phase failures follow Background Retry Policy to failed with resume_status",
       ctx do
    {:ok, _} =
      Repositories.create_repository(ctx.owner, %{
        slug: "fault-fail-#{System.unique_integer([:positive])}",
        name: "FF",
        gpg_key_fingerprint: ctx.pair.fingerprint
      })

    assert {:accepted, transition} = UserWide.start_removal(ctx.owner, "clear_metadata_signing")

    # Drive the failure recorder directly (the guarded batch path calls it
    # on any raised transient error).
    for n <- 1..19 do
      :ok =
        UserWide.__record_phase_failure_for_tests__(
          transition.id,
          "preparing",
          "database_unavailable"
        )

      current = Repo.get!(Transition, transition.id)
      assert current.phase_attempts == n
      assert current.status == "preparing"
      assert current.phase_next_attempt_at

      # Backoff matches min(3600, 30 * 2^(n-1)) from the policy.
      expected = RetryPolicy.backoff(n)
      delta = DateTime.diff(current.phase_next_attempt_at, DateTime.utc_now(:second))
      assert_in_delta delta, expected, 3

      # Re-arm as due so the next failure is recorded against "preparing".
      {1, _} =
        Repo.update_all(
          from(t in Transition, where: t.id == ^transition.id),
          set: [phase_next_attempt_at: DateTime.utc_now(:second)]
        )
    end

    :ok =
      UserWide.__record_phase_failure_for_tests__(
        transition.id,
        "preparing",
        "database_unavailable"
      )

    failed = Repo.get!(Transition, transition.id)
    assert failed.status == "failed"
    assert failed.resume_status == "preparing"
    assert failed.last_error_code == "database_unavailable"
    assert failed.phase_attempts == 20
    assert is_nil(failed.phase_next_attempt_at)

    # The fence still blocks creations while failed-resuming-preparing.
    assert {:error, :gpg_key_transition_in_progress} =
             Repositories.create_repository(ctx.owner, %{slug: "still-fenced", name: "X"})
  end

  test "a run_phase crash inside a batch records one transient failure", ctx do
    {:ok, repo} =
      Repositories.create_repository(ctx.owner, %{
        slug: "fault-crash-#{System.unique_integer([:positive])}",
        name: "FC",
        gpg_key_fingerprint: ctx.pair.fingerprint,
        sign_rpms: true
      })

    insert_package_from_rpm!(repo, minimal_binary())
    sync_repository_metadata_state!(repo)

    assert {:accepted, transition} = UserWide.start_removal(ctx.owner, "delete_signed_packages")

    # Poison the batch: a duplicate snapshot row with a conflicting id makes
    # insert_all raise on the non-conflict path? Instead simulate by making
    # the transition row vanish mid-run is not possible in one process, so
    # assert the rescue path via a bogus batch size.
    Application.put_env(:dark_zenith, :signing_preparation_batch_size, "boom")

    assert :ok = UserWide.run_phase(transition.id)

    Application.put_env(:dark_zenith, :signing_preparation_batch_size, 1)

    current = Repo.get!(Transition, transition.id)
    assert current.status == "preparing"
    assert current.phase_attempts == 1
    assert current.last_error_code == "signing_transition_phase_error"
  end
end
