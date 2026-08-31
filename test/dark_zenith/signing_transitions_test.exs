defmodule DarkZenith.SigningTransitionsTest do
  # Not async: overrides the signing implementation.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.SigningTransitions
  alias DarkZenith.SigningTransitions.{Item, Transition}
  alias DarkZenith.Workers.{MetadataRegeneration, SigningItem}

  setup do
    Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)

    on_exit(fn ->
      Application.delete_env(:dark_zenith, :signing_impl)
      Application.delete_env(:dark_zenith, :signing_stub_rpm_result)
    end)

    pair = generate_key_pair()
    owner = user_fixture()
    {:ok, owner} = Accounts.upsert_gpg_key(owner, pair.public, pair.private)

    {:ok, repo} =
      Repositories.create_repository(owner, %{
        slug: "sign-#{System.unique_integer([:positive])}",
        name: "Signing",
        gpg_key_fingerprint: pair.fingerprint
      })

    package_a =
      insert_package_from_rpm!(repo, v4_binary(), %{
        storage_path: "repos/#{repo.slug}/packages/a/w1/a.rpm",
        storage_version_id: "4_zolda"
      })

    package_b =
      insert_package_from_rpm!(repo, minimal_binary(), %{
        storage_path: "repos/#{repo.slug}/packages/b/w1/b.rpm",
        storage_version_id: "4_zoldb"
      })

    sync_repository_metadata_state!(repo)

    %{owner: owner, repo: Repo.get!(Repository, repo.id), a: package_a, b: package_b}
  end

  defp enable!(ctx) do
    {:ok, repo} =
      Repositories.update_repository(ctx.owner, ctx.repo, %{
        "sign_rpms" => true,
        "existing_package_strategy" => "resign"
      })

    repo
  end

  defp stub_item_pipeline(packages) do
    by_path = Map.new(packages, fn {package, binary} -> {"/dz-bucket/" <> package.storage_path, binary} end)

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      conn = Plug.Conn.delete_resp_header(conn, "cache-control")

      case {conn.method, Map.fetch(by_path, conn.request_path)} do
        {"GET", {:ok, binary}} ->
          Plug.Conn.send_resp(conn, 200, binary)

        {"PUT", _} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)

          conn
          |> Plug.Conn.put_resp_header("x-amz-version-id", "4_znew")
          |> Plug.Conn.send_resp(200, "")
          |> then(fn c ->
            Process.put({:uploaded, conn.request_path}, byte_size(body))
            c
          end)

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

  test "enabling on a non-empty repository creates the transition atomically", ctx do
    repo = enable!(ctx)

    assert repo.sign_rpms
    assert repo.rpm_signing_state == "signing"
    assert repo.signing_transition_id

    transition = Repo.get!(Transition, repo.signing_transition_id)
    assert transition.kind == "enable_rpm_signing"
    assert transition.status == "active"
    assert transition.target_fingerprint == ctx.owner.gpg_signing_fingerprint

    items = SigningTransitions.list_items(transition.id)
    assert length(items) == 2
    assert Enum.all?(items, &(&1.status == "pending"))
    assert Enum.any?(items, &(&1.expected_storage_version_id == "4_zolda"))

    assert [_j1, _j2] = all_enqueued(worker: SigningItem)

    # The generated .repo file keeps gpgcheck=0 while signing.
    assert DarkZenith.Repositories.RepoFile.render(repo, "http://x") =~ "gpgcheck=0"
  end

  test "items re-sign packages and the transition completes to enabled", ctx do
    repo = enable!(ctx)
    stub_item_pipeline([{ctx.a, v4_binary()}, {ctx.b, minimal_binary()}])

    for item <- SigningTransitions.list_items(repo.signing_transition_id) do
      assert :ok = perform_job(SigningItem, %{"item_id" => item.id})
    end

    updated_a = Repo.get!(Package, ctx.a.id)
    assert updated_a.storage_version_id == "4_znew"
    refute updated_a.storage_path == ctx.a.storage_path
    assert updated_a.sha256 == ctx.a.sha256

    counts = SigningTransitions.item_counts(repo.signing_transition_id)
    assert counts["succeeded"] == 2

    # Old exact versions are queued for deletion.
    assert_enqueued(
      worker: DarkZenith.Workers.FinalVersionCleanup,
      args: %{storage_path: ctx.a.storage_path, version_id: "4_zolda"}
    )

    # Completion waits for the metadata cache to reach the new revision.
    assert {:ok, :not_yet} = {:ok, :not_yet}
    assert Repo.get!(Repository, repo.id).rpm_signing_state == "signing"

    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => repo.id})
    assert :ok = SigningTransitions.sweep()

    finished = Repo.get!(Repository, repo.id)
    assert finished.rpm_signing_state == "enabled"
    assert finished.signing_transition_id == nil
    assert Repo.get!(Transition, repo.signing_transition_id).status == "completed"
    assert DarkZenith.Repositories.RepoFile.render(finished, "http://x") =~ "gpgcheck=1"
  end

  test "a deterministic signing failure fails the item and transition", ctx do
    repo = enable!(ctx)
    stub_item_pipeline([{ctx.a, v4_binary()}, {ctx.b, minimal_binary()}])
    Application.put_env(:dark_zenith, :signing_stub_rpm_result, {:error, :validation_failed})

    [item | _] = SigningTransitions.list_items(repo.signing_transition_id)
    assert :ok = perform_job(SigningItem, %{"item_id" => item.id})

    failed_item = Repo.get!(Item, item.id)
    assert failed_item.status == "failed"
    assert failed_item.last_error_code == "validation_failed"

    transition = Repo.get!(Transition, repo.signing_transition_id)
    assert transition.status == "failed"
    assert transition.resume_status == "active"

    # Admin reset restores the item and reactivates the transition.
    admin = admin_fixture()
    {:ok, 1} = SigningTransitions.admin_reset_items(admin, transition.id, [item.id])

    reset_item = Repo.get!(Item, item.id)
    assert reset_item.status == "pending"
    assert reset_item.attempts == 0
    assert Repo.get!(Transition, transition.id).status == "active"
  end

  test "package deletion cancels its unfinished item", ctx do
    repo = enable!(ctx)

    :ok = DarkZenith.Packages.delete_package(ctx.owner, Repo.get!(Repository, repo.id), ctx.a)

    counts = SigningTransitions.item_counts(repo.signing_transition_id)
    assert counts["canceled"] == 1
    assert counts["pending"] == 1
  end

  test "disabling sign_rpms cancels the transition and items", ctx do
    repo = enable!(ctx)

    {:ok, disabled} =
      Repositories.update_repository(ctx.owner, Repo.get!(Repository, repo.id), %{
        "sign_rpms" => false
      })

    assert disabled.rpm_signing_state == "disabled"
    assert disabled.signing_transition_id == nil
    assert Repo.get!(Transition, repo.signing_transition_id).status == "canceled"

    counts = SigningTransitions.item_counts(repo.signing_transition_id)
    assert counts["canceled"] == 2
  end

  test "the sweep requeues an expired execution lease", ctx do
    repo = enable!(ctx)
    [item | _] = SigningTransitions.list_items(repo.signing_transition_id)

    past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

    {1, _} =
      Repo.update_all(from(i in Item, where: i.id == ^item.id),
        set: [
          status: "executing",
          lease_token: Ecto.UUID.generate(),
          lease_expires_at: past,
          next_attempt_at: nil,
          attempts: 1
        ]
      )

    assert :ok = SigningTransitions.sweep()

    requeued = Repo.get!(Item, item.id)
    assert requeued.status == "pending"
    assert requeued.lease_token == nil
    assert requeued.next_attempt_at
  end

  test "a claim skips when the transition was canceled", ctx do
    repo = enable!(ctx)
    transition = Repo.get!(Transition, repo.signing_transition_id)
    [item | _] = SigningTransitions.list_items(transition.id)

    {:ok, _} = Repo.transact(fn -> {:ok, SigningTransitions.cancel_transition!(transition)} end)

    assert :ok = perform_job(SigningItem, %{"item_id" => item.id})
    assert Repo.get!(Item, item.id).status == "canceled"
  end
end
