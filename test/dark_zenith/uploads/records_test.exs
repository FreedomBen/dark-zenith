defmodule DarkZenith.Uploads.RecordsTest do
  @moduledoc """
  Package upload records (DESIGN.md: Package Upload Records): the durable,
  append-mostly counterpart of an upload intent that outlives the intent,
  the repository, and the initiator's account.
  """
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.B2StubHelpers
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures
  import DarkZenith.UploadsFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenith.Repositories
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.{Intent, Record, Records}
  alias DarkZenith.Workers.{UploadProcessing, UploadTerminalCleanup}

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp create!(ctx, attrs \\ %{}) do
    {:ok, intent, _upload} =
      Uploads.create_intent(
        ctx.owner,
        ctx.repo,
        Map.merge(%{filename: "pkg.rpm", size: 1000, mode: "api"}, attrs)
      )

    intent
  end

  defp record_for(intent), do: Records.get_by_intent(intent.id)

  defp upload_events(action \\ "package.upload") do
    Audit.list_events(action: action, limit: 50)
    |> Enum.filter(&(&1.action == action))
  end

  describe "creation" do
    test "an intent's creation transaction writes its in_flight record", ctx do
      intent = create!(ctx, %{filename: "dir/nginx.rpm", size: 623_104})

      assert %Record{} = record = record_for(intent)
      assert record.repository_id == ctx.repo.id
      assert record.repository_slug == ctx.repo.slug
      assert record.user_id == ctx.owner.id
      assert record.user_email == ctx.owner.email
      assert record.intent_id == intent.id
      assert record.package_id == intent.package_id
      assert record.mode == "api"
      assert record.original_filename == "nginx.rpm"
      assert record.declared_size == 623_104
      assert record.outcome == "in_flight"
      assert record.final_size == nil
      assert record.nevra == nil
      assert record.error_code == nil
      assert record.error_detail == nil
      assert record.finished_at == nil

      # started_at snapshots the intent's own start; inserted_at is when the
      # row was written — the same moment for a record written with its intent.
      assert record.started_at == intent.inserted_at
      assert DateTime.diff(record.inserted_at, record.started_at) in 0..1
    end

    test "the creation audit event is self-sufficient and resolves to the record", ctx do
      intent = create!(ctx)
      record = record_for(intent)

      assert [event] = upload_events("package.upload_intent_create")
      assert event.target_type == "upload_intent"
      assert event.target_id == intent.id
      assert event.metadata["repository_id"] == ctx.repo.id
      assert event.metadata["repository_slug"] == ctx.repo.slug
      assert event.metadata["intent_id"] == intent.id
      assert event.metadata["upload_record_id"] == record.id
      assert event.metadata["original_filename"] == "pkg.rpm"
      assert event.metadata["declared_size"] == "1000"
      assert event.metadata["mode"] == "api"
    end
  end

  describe "finalization" do
    test "cancellation finalizes the record as canceled in the same transaction", ctx do
      intent = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, intent)

      record = record_for(intent)
      assert record.outcome == "canceled"
      assert record.finished_at
      assert record.error_code == nil

      assert [event] = upload_events("package.upload_intent_cancel")
      assert event.metadata["upload_record_id"] == record.id
      assert event.metadata["repository_slug"] == ctx.repo.slug
      assert event.metadata["original_filename"] == "pkg.rpm"
    end

    test "an overdue completion attempt expires the record and audits the actor", ctx do
      intent = create!(ctx)
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])

      assert {:error, :upload_state} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zv")

      record = record_for(intent)
      assert record.outcome == "expired"
      assert record.finished_at

      assert [event] = upload_events()
      assert event.metadata["result"] == "expired"
      assert event.target_type == "upload_intent"
      assert event.target_id == intent.id
      assert event.actor_id == ctx.owner.id
      assert event.metadata["upload_record_id"] == record.id
      assert event.metadata["intent_id"] == intent.id
      assert event.metadata["repository_id"] == ctx.repo.id
    end

    test "the waiting-state sweep expires the record with a system audit event", ctx do
      intent = create!(ctx)
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])

      Uploads.expire_overdue()

      assert record_for(intent).outcome == "expired"

      assert [event] = upload_events()
      assert event.metadata["result"] == "expired"
      assert event.target_id == intent.id
      assert event.actor_id == nil
      assert event.actor_email == nil
      assert event.ip == nil
      assert event.metadata["upload_record_id"] == record_for(intent).id
    end

    test "a terminal failure records the sanitized code and reason", ctx do
      intent = create!(ctx)

      {:ok, _} =
        Repo.transact(fn ->
          Uploads.terminalize!(intent, "failed", "validation_failed", "bad_lead_magic")
          {:ok, :ok}
        end)

      record = record_for(intent)
      assert record.outcome == "failed"
      assert record.error_code == "validation_failed"
      assert record.error_detail == "bad_lead_magic"
      assert record.final_size == nil
      assert record.nevra == nil
      assert record.finished_at
    end

    test "success writes final_size and nevra and the audit event carries the record", ctx do
      binary = v4_binary()
      intent = create!(ctx, %{filename: "upload.rpm", size: byte_size(binary)})
      stub_pipeline(intent, binary)
      {:ok, queued} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zstaged")
      assert :ok = perform_job(UploadProcessing, %{"intent_id" => queued.id})

      record = record_for(intent)
      assert record.outcome == "succeeded"
      assert record.final_size == byte_size(binary)
      assert record.nevra =~ ~r/^dz-fixture-2:.+\.noarch$/
      assert record.error_code == nil
      assert record.finished_at

      assert [event] =
               Enum.filter(upload_events(), &(&1.metadata["result"] == "succeeded"))

      assert event.target_type == "package"
      assert event.target_id == intent.package_id
      assert event.metadata["nevra"] == record.nevra
      assert event.metadata["upload_record_id"] == record.id
      assert event.metadata["intent_id"] == intent.id
      assert event.metadata["repository_slug"] == ctx.repo.slug
      assert event.metadata["original_filename"] == "upload.rpm"
    end

    test "finalization is a single compare-and-swap on in_flight", ctx do
      intent = create!(ctx)

      assert :ok = Records.finalize!(intent.id, "failed", error_code: "storage_unavailable")
      assert :noop = Records.finalize!(intent.id, "canceled")
      assert :noop = Records.finalize!(intent.id, "succeeded", final_size: 1, nevra: "x")

      record = record_for(intent)
      assert record.outcome == "failed"
      assert record.error_code == "storage_unavailable"
      assert record.nevra == nil
    end

    test "a replayed terminal transition cannot rewrite the recorded outcome", ctx do
      intent = create!(ctx)
      {:ok, canceled} = Uploads.cancel_intent(ctx.owner, intent)
      finished_at = record_for(intent).finished_at

      # A racing worker that still holds a stale struct reaches the same
      # terminal helper; the record keeps its first outcome.
      {:ok, _} =
        Repo.transact(fn ->
          Uploads.terminalize!(canceled, "failed", "storage_unavailable")
          {:ok, :ok}
        end)

      record = record_for(intent)
      assert record.outcome == "canceled"
      assert record.finished_at == finished_at
      assert record.error_code == nil
    end
  end

  describe "durability" do
    test "the record survives the hourly intent cleanup", ctx do
      intent = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, intent)
      old = DateTime.add(DateTime.utc_now(:second), -25, :hour)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [completed_at: old])

      assert :ok = perform_job(UploadTerminalCleanup, %{})

      refute Repo.get(Intent, intent.id)
      record = record_for(intent)
      assert record.outcome == "canceled"
      assert record.intent_id == intent.id
    end

    test "repository deletion cancels in_flight records and retains every record", ctx do
      in_flight = create!(ctx)
      done = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, done)
      done_finished_at = record_for(done).finished_at

      assert :ok = Repositories.delete_repository(ctx.owner, ctx.repo)

      refute Repo.get(Intent, in_flight.id)

      canceled = record_for(in_flight)
      assert canceled.outcome == "canceled"
      assert canceled.finished_at
      assert canceled.repository_id == ctx.repo.id
      assert canceled.repository_slug == ctx.repo.slug

      # An already terminal record is untouched.
      assert record_for(done).finished_at == done_finished_at
    end

    test "initiator deletion clears user_id, keeps the email snapshot, and cancels", ctx do
      actor = admin_fixture()
      initiator = admin_fixture()

      {:ok, intent, _} =
        Uploads.create_intent(initiator, ctx.repo, %{filename: "a.rpm", size: 10, mode: "api"})

      assert record_for(intent).user_id == initiator.id

      assert {:ok, :ok} = Accounts.admin_delete_user(actor, initiator.id)

      record = record_for(intent)
      assert record.user_id == nil
      assert record.user_email == initiator.email
      assert record.outcome == "canceled"
      assert record.finished_at
    end

    test "the hourly sweep finalizes an in_flight record whose intent vanished", ctx do
      intent = create!(ctx)
      live = create!(ctx)

      # An intent that disappeared by a route the rules did not anticipate.
      Repo.delete_all(from(i in Intent, where: i.id == ^intent.id))

      before = DateTime.utc_now(:second)
      assert :ok = perform_job(UploadTerminalCleanup, %{})

      orphan = record_for(intent)
      assert orphan.outcome == "canceled"
      assert DateTime.compare(orphan.finished_at, before) != :lt

      # The sweep repairs state; it records no audit event for it.
      assert upload_events("package.upload_intent_cancel") == []

      # A record whose intent still exists is left alone.
      assert record_for(live).outcome == "in_flight"
    end

    test "the record survives deletion of the resulting package", ctx do
      binary = v4_binary()
      intent = create!(ctx, %{filename: "upload.rpm", size: byte_size(binary)})
      stub_pipeline(intent, binary)
      {:ok, queued} = Uploads.complete_intent(ctx.owner, intent, 1, "4_zstaged")
      assert :ok = perform_job(UploadProcessing, %{"intent_id" => queued.id})

      package = Repo.get!(DarkZenith.Packages.Package, intent.package_id)
      repo = Repositories.get_repository!(ctx.repo.id)
      assert :ok = DarkZenith.Packages.delete_package(ctx.owner, repo, package)

      record = record_for(intent)
      assert record.outcome == "succeeded"
      assert record.package_id == intent.package_id
      assert record.nevra
    end
  end

  describe "list_repository_records/2" do
    test "orders by started_at descending then id ascending", ctx do
      oldest = create!(ctx, %{filename: "oldest.rpm"})
      middle = create!(ctx, %{filename: "middle.rpm"})
      newest = create!(ctx, %{filename: "newest.rpm"})

      base = DateTime.utc_now(:second)

      for {intent, offset} <- [{oldest, -300}, {middle, -200}, {newest, -100}] do
        Repo.update_all(
          from(r in Record, where: r.intent_id == ^intent.id),
          set: [started_at: DateTime.add(base, offset, :second)]
        )
      end

      {rows, total} = Uploads.list_repository_records(ctx.repo, page: 1, per_page: 25)
      assert total == 3
      assert Enum.map(rows, & &1.original_filename) == ["newest.rpm", "middle.rpm", "oldest.rpm"]
    end

    test "equal start times fall back to id ascending", ctx do
      a = create!(ctx)
      b = create!(ctx)
      c = create!(ctx)
      same = DateTime.add(DateTime.utc_now(:second), -60, :second)

      Repo.update_all(
        from(r in Record, where: r.repository_id == ^ctx.repo.id),
        set: [started_at: same]
      )

      {rows, _} = Uploads.list_repository_records(ctx.repo, page: 1, per_page: 25)
      ids = Enum.map([a, b, c], &record_for(&1).id) |> Enum.sort()
      assert Enum.map(rows, & &1.id) == ids
    end

    test "live_status refines in_flight and nothing else", ctx do
      in_flight = create!(ctx)
      terminal = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, terminal)
      orphan = create!(ctx)
      Repo.delete_all(from(i in Intent, where: i.id == ^orphan.id))

      {rows, 3} = Uploads.list_repository_records(ctx.repo, page: 1, per_page: 25)
      by_intent = Map.new(rows, &{&1.intent_id, &1})

      assert by_intent[in_flight.id].outcome == "in_flight"
      assert by_intent[in_flight.id].live_status == "awaiting_upload"

      # A terminal record reads null even while its intent is still retained.
      assert Repo.get(Intent, terminal.id)
      assert by_intent[terminal.id].outcome == "canceled"
      assert by_intent[terminal.id].live_status == nil

      # An in_flight record whose intent is gone is awaiting reconciliation.
      assert by_intent[orphan.id].outcome == "in_flight"
      assert by_intent[orphan.id].live_status == nil
      # And intent_id is always the stored snapshot.
      assert by_intent[orphan.id].intent_id == orphan.id
    end

    test "filters by an outcome subset and paginates", ctx do
      a = create!(ctx)
      _b = create!(ctx)
      c = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, a)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, c)

      {rows, 2} =
        Uploads.list_repository_records(ctx.repo, outcomes: ["canceled"], page: 1, per_page: 25)

      assert Enum.all?(rows, &(&1.outcome == "canceled"))

      {rows, 3} =
        Uploads.list_repository_records(ctx.repo,
          outcomes: ["canceled", "in_flight"],
          page: 2,
          per_page: 2
        )

      assert length(rows) == 1

      {rows, 0} =
        Uploads.list_repository_records(ctx.repo, outcomes: ["failed"], page: 1, per_page: 25)

      assert rows == []
    end

    test "is scoped to the repository", ctx do
      other_repo = repository_fixture(ctx.owner)
      create!(ctx)

      {:ok, _, _} =
        Uploads.create_intent(ctx.owner, other_repo, %{filename: "o.rpm", size: 5, mode: "api"})

      {rows, 1} = Uploads.list_repository_records(ctx.repo, page: 1, per_page: 25)
      assert [%{repository_id: id}] = rows
      assert id == ctx.repo.id
    end
  end

  describe "in_flight_count/1" do
    test "counts only the repository's in_flight records, orphans included", ctx do
      create!(ctx)
      orphan = create!(ctx)
      Repo.delete_all(from(i in Intent, where: i.id == ^orphan.id))
      done = create!(ctx)
      {:ok, _} = Uploads.cancel_intent(ctx.owner, done)

      other_repo = repository_fixture(ctx.owner)

      {:ok, _, _} =
        Uploads.create_intent(ctx.owner, other_repo, %{filename: "o.rpm", size: 5, mode: "api"})

      assert Records.in_flight_count(ctx.repo.id) == 2
    end
  end

  describe "parse_outcome_filter/1" do
    test "accepts an exact comma-separated subset" do
      assert Records.parse_outcome_filter(nil) == {:ok, nil}
      assert Records.parse_outcome_filter("in_flight") == {:ok, ["in_flight"]}

      assert Records.parse_outcome_filter("failed,canceled,expired") ==
               {:ok, ["failed", "canceled", "expired"]}
    end

    test "rejects unknown, blank, folded, trimmed, or repeated entries" do
      for bad <- [
            "",
            ",",
            "in_flight,",
            "done",
            "Failed",
            " failed",
            "failed, canceled",
            "failed,failed",
            "in_flight,,canceled"
          ] do
        assert {:error, _message} = Records.parse_outcome_filter(bad), inspect(bad)
      end
    end
  end

  describe "admin listing" do
    test "filters by exact slug and email snapshots plus outcome", ctx do
      other_owner = user_fixture()
      other_repo = repository_fixture(other_owner)
      mine = create!(ctx)

      {:ok, theirs, _} =
        Uploads.create_intent(other_owner, other_repo, %{filename: "t.rpm", size: 5, mode: "api"})

      {:ok, _} = Uploads.cancel_intent(other_owner, theirs)

      {rows, 2} = Records.list_admin_records(page: 1, per_page: 25)
      assert length(rows) == 2

      {rows, 1} = Records.list_admin_records(repository: ctx.repo.slug, page: 1, per_page: 25)
      assert [%{intent_id: id}] = rows
      assert id == mine.id

      {rows, 1} = Records.list_admin_records(initiator: other_owner.email, page: 1, per_page: 25)
      assert [%{intent_id: id}] = rows
      assert id == theirs.id

      {rows, 1} = Records.list_admin_records(outcomes: ["canceled"], page: 1, per_page: 25)
      assert [%{intent_id: id}] = rows
      assert id == theirs.id

      {[], 0} = Records.list_admin_records(repository: "no-such-slug", page: 1, per_page: 25)
    end

    test "a record deleted with its repository stays listed with no live repository", ctx do
      intent = create!(ctx)
      live_repo = repository_fixture(ctx.owner)

      {:ok, live_intent, _} =
        Uploads.create_intent(ctx.owner, live_repo, %{filename: "l.rpm", size: 5, mode: "api"})

      assert :ok = Repositories.delete_repository(ctx.owner, ctx.repo)

      {rows, 2} = Records.list_admin_records(page: 1, per_page: 25)
      assert Enum.any?(rows, &(&1.intent_id == intent.id and &1.repository_slug == ctx.repo.slug))

      live = Records.live_repositories(Enum.map(rows, & &1.repository_id))
      assert live == %{live_repo.id => live_repo.slug}
      assert record_for(live_intent).repository_id == live_repo.id
    end
  end

  describe "backfill" do
    setup do
      # The migration is not part of the compiled application; load it so
      # its backfill statement can be exercised against live rows.
      [path] = Path.wildcard("priv/repo/migrations/*_create_package_upload_records.exs")

      unless Code.ensure_loaded?(DarkZenith.Repo.Migrations.CreatePackageUploadRecords) do
        Code.require_file(path)
      end

      :ok
    end

    test "writes one record per intent lacking one, per the DESIGN.md rule", ctx do
      binary = v4_binary()
      user = ctx.owner
      repo = ctx.repo

      started = DateTime.add(DateTime.utc_now(:second), -7200, :second)
      finished = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      succeeded_res = reservation_row_fixture(user, repo)

      succeeded =
        awaiting_intent_row_fixture(repo, user, succeeded_res, %{
          original_filename: "ok.rpm",
          inserted_at: started
        })

      Repo.update_all(from(i in Intent, where: i.id == ^succeeded.id),
        set: [
          status: "succeeded",
          reservation_id: nil,
          completed_at: finished,
          expires_at: nil,
          upload_url_expires_at: nil
        ]
      )

      package =
        DarkZenith.PackagesFixtures.insert_package_from_rpm!(repo, binary, %{
          id: succeeded.package_id
        })

      gone_res = reservation_row_fixture(user, repo)
      gone = awaiting_intent_row_fixture(repo, user, gone_res, %{original_filename: "gone.rpm"})

      Repo.update_all(from(i in Intent, where: i.id == ^gone.id),
        set: [
          status: "succeeded",
          reservation_id: nil,
          completed_at: finished,
          expires_at: nil,
          upload_url_expires_at: nil
        ]
      )

      failed_res = reservation_row_fixture(user, repo)

      failed =
        awaiting_intent_row_fixture(repo, user, failed_res, %{original_filename: "bad.rpm"})

      Repo.update_all(from(i in Intent, where: i.id == ^failed.id),
        set: [
          status: "failed",
          reservation_id: nil,
          completed_at: finished,
          expires_at: nil,
          upload_url_expires_at: nil,
          last_error_code: "validation_failed",
          last_error_detail: "truncated"
        ]
      )

      waiting_res = reservation_row_fixture(user, repo)

      waiting =
        awaiting_intent_row_fixture(repo, user, waiting_res, %{original_filename: "w.rpm"})

      # Fixture rows were inserted directly, so no record exists yet; the
      # migration statement is idempotent for rows that already have one.
      already = create!(ctx)
      assert Repo.aggregate(Record, :count) == 1

      # A runtime lookup: the migration module is not compiled with the app.
      migration = Module.concat([DarkZenith.Repo.Migrations, CreatePackageUploadRecords])
      Repo.query!(migration.backfill_sql())

      assert Repo.aggregate(Record, :count) == 5
      assert Repo.aggregate(from(r in Record, where: r.intent_id == ^already.id), :count) == 1

      ok = Records.get_by_intent(succeeded.id)
      assert ok.outcome == "succeeded"
      assert ok.repository_slug == repo.slug
      assert ok.user_email == user.email
      assert ok.original_filename == "ok.rpm"
      assert ok.started_at == succeeded.inserted_at
      assert ok.finished_at == finished
      assert ok.final_size == package.size_package

      assert ok.nevra ==
               "#{package.name}-#{package.epoch}:#{package.version}-#{package.release}.#{package.arch}"

      # inserted_at is the migration time, which is why it is a separate column.
      assert DateTime.compare(ok.inserted_at, ok.started_at) == :gt

      # A succeeded intent whose package row is already gone: the one case
      # in which a succeeded record lacks nevra and final_size.
      missing = Records.get_by_intent(gone.id)
      assert missing.outcome == "succeeded"
      assert missing.nevra == nil
      assert missing.final_size == nil

      bad = Records.get_by_intent(failed.id)
      assert bad.outcome == "failed"
      assert bad.error_code == "validation_failed"
      assert bad.error_detail == "truncated"

      pending = Records.get_by_intent(waiting.id)
      assert pending.outcome == "in_flight"
      assert pending.finished_at == nil
    end
  end
end
