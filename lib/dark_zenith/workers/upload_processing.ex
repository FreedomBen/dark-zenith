defmodule DarkZenith.Workers.UploadProcessing do
  @moduledoc """
  The upload processing pipeline (DESIGN.md: Package Upload & Processing
  steps 1–10).

  Claims a queued intent with a fresh lease token, leases node-local
  temporary space, downloads the exact staging version, verifies integrity
  with RPM 6 `rpmkeys` against an empty temporary database, parses and
  validates metadata in Elixir, enforces the metadata limits and duplicate
  checks, adjusts the storage reservation to the exact final size, writes a
  fresh final version via exact-version server-side copy, verifies it with
  `HeadObject`, and commits the package in one fenced transaction using the
  global lock order. Web-preview intents stop at `preview_ready` on their
  first pass and re-verify metadata equality after confirmation.

  Deterministic failures terminally fail the intent; infrastructure
  failures requeue it under Background Retry Policy with the durable
  20-attempt budget. Oban retries only cover worker crashes — the durable
  intent state machine owns scheduling.
  """

  use Oban.Worker,
    queue: :rpm_processing,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:intent_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.B2
  alias DarkZenith.Packages
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Storage
  alias DarkZenith.Storage.Reservation
  alias DarkZenith.TempSpace
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent
  alias DarkZenith.Workers.RetryPolicy

  @lease_seconds 900
  @max_attempts 20
  @max_final_key_bytes 1024

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"intent_id" => intent_id}}) do
    case claim(intent_id) do
      :skip ->
        :ok

      {:ok, intent, token} ->
        case TempSpace.acquire(temp_space(), token, intent.declared_size) do
          {:ok, dir} ->
            try do
              run(intent, token, dir)
            after
              TempSpace.release(temp_space(), token)
            end

          {:error, :upload_temp_space_unavailable} ->
            infra_failure(intent, token, "upload_temp_space_unavailable")
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  ## Claim

  defp claim(intent_id) do
    now = DateTime.utc_now(:second)
    token = Ecto.UUID.generate()

    {:ok, result} =
      Repo.transact(fn ->
        intent = Uploads.lock_intent!(intent_id)

        if intent && intent.status == "queued" &&
             DateTime.compare(intent.next_attempt_at, now) != :gt do
          {1, _} =
            Repo.update_all(
              from(i in Intent, where: i.id == ^intent.id),
              set: [
                status: "processing",
                lease_token: token,
                lease_expires_at: DateTime.add(now, @lease_seconds, :second),
                next_attempt_at: nil,
                updated_at: now
              ],
              inc: [attempts: 1]
            )

          Storage.renew_reservation(intent.reservation_id)
          {:ok, {:ok, Repo.get!(Intent, intent.id), token}}
        else
          {:ok, :skip}
        end
      end)

    result
  end

  ## Pipeline

  defp run(intent, token, dir) do
    config = B2.config!()
    repository = Repo.get(Repository, intent.repository_id)
    source_path = Path.join(dir, "source.rpm")

    with {:repo, %Repository{}} <- {:repo, repository},
         {:ok, sign_snapshot, owner} <- signing_snapshot(repository),
         :ok <- download_source(config, intent, source_path),
         {:ok, measured_size, sha256} <- measure(source_path, intent),
         :ok <- verify_integrity(source_path, dir),
         {:ok, metadata} <- parse_metadata(source_path),
         {:ok, final} <-
           signing_step(sign_snapshot, owner, source_path, dir, metadata, measured_size, sha256),
         :ok <-
           continue(intent, token, repository, final, sign_snapshot, config) do
      :ok
    else
      {:repo, nil} ->
        # Repository deleted; the cascade removed the intent. Nothing to do.
        :ok

      {:error, {:deterministic, code}} ->
        deterministic_failure(intent, token, code)

      {:error, {:infra, code}} ->
        infra_failure(intent, token, code)
    end
  end

  defp continue(intent, token, repository, final, sign_snapshot, config) do
    cond do
      intent.mode == "web_preview" and is_nil(intent.preview_metadata) ->
        preview_transition(intent, token, final.metadata)

      intent.mode == "web_preview" and
          intent.preview_metadata != Uploads.preview_metadata(final.metadata) ->
        {:error, {:deterministic, "validation_failed"}}

      true ->
        finalize(intent, token, repository, final, sign_snapshot, config)
    end
  end

  defp finalize(intent, token, repository, final, sign_snapshot, config) do
    now = DateTime.utc_now(:second)

    candidate =
      candidate_package(intent, repository, final.metadata, final.size, final.sha256, now)

    with :ok <- advisory_limits(repository, candidate),
         :ok <- advisory_duplicate(repository, final.metadata),
         :ok <- adjust_reservation(intent, final.size),
         {:ok, final_key} <- compose_final_key(repository, intent, final.metadata),
         {:ok, final_version} <- write_final(config, final_key, intent, final),
         :ok <- verify_final(config, final_key, final_version, final.size) do
      commit(
        intent,
        token,
        repository,
        %{candidate | storage_path: final_key, storage_version_id: final_version},
        sign_snapshot,
        config
      )
    end
  end

  ## Steps 1–3 helpers

  defp download_source(config, intent, source_path) do
    case B2.download_to_file(config, intent.staging_path, intent.staging_version_id, source_path) do
      :ok -> :ok
      {:error, _} -> {:error, {:infra, "storage_unavailable"}}
    end
  end

  defp measure(source_path, intent) do
    %{size: size} = File.stat!(source_path)

    if size == intent.declared_size do
      {:ok, size, stream_sha256(source_path)}
    else
      # The accepted immutable version no longer matches its verified length.
      {:error, {:infra, "storage_unavailable"}}
    end
  end

  defp stream_sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Step 2: rpmkeys against an isolated empty database. Any BAD digest or
  # signature rejects; NOTFOUND/NOKEY signers and absent digests pass, but at
  # least one digest must verify OK.
  defp verify_integrity(source_path, dir) do
    dbpath = Path.join(dir, "rpmdb")
    File.mkdir_p!(dbpath)
    File.chmod!(dbpath, 0o700)

    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")

    try do
      {output, _status} =
        System.cmd(rpmkeys, ["--dbpath", dbpath, "--checksig", "--verbose", source_path],
          env: [{"LC_ALL", "C"}],
          stderr_to_stdout: true
        )

      analyze_checksig(output)
    rescue
      ErlangError -> {:error, {:infra, "rpm_verification_unavailable"}}
    end
  end

  defp analyze_checksig(output) do
    results =
      for line <- String.split(output, "\n"),
          match = Regex.run(~r/^\s+(.+?):\s+(OK|BAD|NOTFOUND|NOKEY)\b/, line),
          do: {Enum.at(match, 1), Enum.at(match, 2)}

    digest_ok? =
      Enum.any?(results, fn {name, status} ->
        String.contains?(String.downcase(name), "digest") and status == "OK"
      end)

    any_bad? = Enum.any?(results, fn {_name, status} -> status == "BAD" end)

    if any_bad? or not digest_ok? do
      {:error, {:deterministic, "validation_failed"}}
    else
      :ok
    end
  end

  defp parse_metadata(source_path) do
    case DarkZenith.Rpm.parse(File.read!(source_path)) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, _reason} -> {:error, {:deterministic, "validation_failed"}}
    end
  end

  ## Step 4: signing snapshot and dispatch

  # The snapshot fences the final transaction against settings and key
  # changes that raced the attempt (DESIGN.md: step 4/step 10).
  defp signing_snapshot(repository) do
    owner = Repo.get(User, repository.user_id)

    if owner do
      {:ok,
       %{
         sign_rpms: repository.sign_rpms,
         gpg_key_fingerprint: repository.gpg_key_fingerprint,
         owner_signing_fingerprint: owner.gpg_signing_fingerprint,
         owner_public_key: owner.gpg_key_public
       }, owner}
    else
      {:repo, nil}
    end
  end

  # Unsigned path: the staged bytes are final.
  defp signing_step(%{sign_rpms: false}, _owner, source_path, _dir, metadata, size, sha256) do
    {:ok, %{path: source_path, metadata: metadata, size: size, sha256: sha256, signed?: false}}
  end

  defp signing_step(%{sign_rpms: true} = snapshot, owner, source_path, dir, metadata, _size, _sha) do
    cond do
      is_nil(snapshot.owner_signing_fingerprint) ->
        # sign_rpms enabled with no configured key rejects the upload.
        {:error, {:deterministic, "validation_failed"}}

      true ->
        case DarkZenith.Signing.sign_rpm(owner, source_path, dir, metadata.rpm_format) do
          {:ok, signed_path} ->
            signed_final(signed_path, metadata)

          {:error, :expired} ->
            {:error, {:deterministic, "conflict_gpg_key_expired"}}

          {:error, :validation_failed} ->
            {:error, {:deterministic, "validation_failed"}}

          {:error, :rpm_verification_unavailable} ->
            {:error, {:infra, "rpm_verification_unavailable"}}

          {:error, _unavailable} ->
            {:error, {:infra, "signing_unavailable"}}
        end
    end
  end

  # Step 5: final values are computed from the signed bytes — signing moves
  # the main header, so offsets and the v4 archive size are re-read, and the
  # persisted size must still obey the upload ceiling.
  defp signed_final(signed_path, original_metadata) do
    %{size: size} = File.stat!(signed_path)
    max = Application.get_env(:dark_zenith, :max_rpm_upload_bytes, 536_870_912)

    cond do
      size > max ->
        {:error, {:deterministic, "payload_too_large"}}

      true ->
        case DarkZenith.Rpm.parse(File.read!(signed_path)) do
          {:ok, signed_metadata} ->
            metadata = %{
              original_metadata
              | header_start: signed_metadata.header_start,
                header_end: signed_metadata.header_end,
                size_archive: signed_metadata.size_archive
            }

            {:ok,
             %{
               path: signed_path,
               metadata: metadata,
               size: size,
               sha256: stream_sha256(signed_path),
               signed?: true
             }}

          {:error, _reason} ->
            {:error, {:deterministic, "validation_failed"}}
        end
    end
  end

  ## Steps 6–9

  defp candidate_package(intent, repository, metadata, final_size, final_sha, now) do
    attrs =
      metadata
      |> Packages.metadata_attrs()
      |> Map.merge(%{
        id: intent.package_id,
        repository_id: repository.id,
        sha256: final_sha,
        size_package: final_size,
        storage_path: "pending",
        storage_version_id: "pending",
        inserted_at: now,
        updated_at: now
      })

    struct!(Package, attrs)
  end

  defp advisory_limits(repository, candidate) do
    check_limits(repository, candidate)
  end

  defp check_limits(repository, candidate) do
    projected_count = repository.package_count + 1
    entry_sizes = Repodata.entry_open_sizes(candidate)
    overhead_now = Repodata.document_overhead(repository.package_count)
    overhead_next = Repodata.document_overhead(projected_count)

    projected = fn counter, key ->
      counter + Map.fetch!(entry_sizes, key) +
        (Map.fetch!(overhead_next, key) - Map.fetch!(overhead_now, key))
    end

    limit = max_repodata_open_bytes()

    over? =
      projected_count > max_repository_packages() or
        projected.(repository.primary_open_bytes, :primary) > limit or
        projected.(repository.filelists_open_bytes, :filelists) > limit or
        projected.(repository.other_open_bytes, :other) > limit

    if over? do
      {:error, {:deterministic, "conflict_repository_metadata_limit_exceeded"}}
    else
      :ok
    end
  end

  defp advisory_duplicate(repository, metadata) do
    duplicate_check(repository.id, metadata)
  end

  defp duplicate_check(repository_id, metadata) do
    exists? =
      Repo.exists?(
        from p in Package,
          where:
            p.repository_id == ^repository_id and p.name == ^metadata.name and
              p.epoch == ^metadata.epoch and p.version == ^metadata.version and
              p.release == ^metadata.release and p.arch == ^metadata.arch
      )

    if exists? do
      {:error, {:deterministic, "conflict_duplicate_package"}}
    else
      :ok
    end
  end

  defp adjust_reservation(intent, final_size) do
    case Storage.adjust_reservation(intent.reservation_id, final_size) do
      {:ok, _reservation} -> :ok
      {:error, :quota_exceeded} -> {:error, {:deterministic, "conflict_storage_quota_exceeded"}}
      # The reservation is gone: a cancel fenced this attempt.
      {:error, :not_found} -> {:error, {:deterministic, "conflict_upload_state"}}
    end
  end

  defp compose_final_key(repository, intent, metadata) do
    write_id = Ecto.UUID.generate()

    key =
      "repos/#{repository.slug}/packages/#{intent.package_id}/#{write_id}/" <>
        "#{metadata.name}-#{metadata.epoch}-#{metadata.version}-#{metadata.release}." <>
        "#{metadata.arch}.rpm"

    if byte_size(key) > @max_final_key_bytes do
      {:error, {:deterministic, "validation_failed"}}
    else
      {:ok, key}
    end
  end

  # Step 9: unsigned packages are server-side copied from the exact staging
  # version; signed packages upload the verified local output.
  defp write_final(config, final_key, intent, final) do
    result =
      if final.signed? do
        B2.put_object(config, final_key, File.read!(final.path))
      else
        B2.copy_object(config, final_key, intent.staging_path, intent.staging_version_id)
      end

    case result do
      {:ok, version} -> {:ok, version}
      {:error, :storage_unavailable} -> {:error, {:infra, "storage_unavailable"}}
    end
  end

  defp verify_final(config, final_key, final_version, final_size) do
    case B2.head_object(config, final_key, final_version) do
      {:ok, head} ->
        case B2.verify_object_contract(head, final_size) do
          :ok ->
            :ok

          {:error, _violation} ->
            _ = B2.delete_version(config, final_key, final_version)
            {:error, {:infra, "storage_unavailable"}}
        end

      {:error, _} ->
        # Ambiguous candidate: abandon it to the reconciler.
        {:error, {:infra, "storage_unavailable"}}
    end
  end

  ## Step 10: the fenced final transaction

  defp commit(intent, token, repository, candidate, sign_snapshot, config) do
    {:ok, result} =
      Repo.transact(fn ->
        # Global lock order: owner, repository, (packages), intent, reservation.
        owner =
          Repo.one!(
            from u in User, where: u.id == ^repository.user_id, lock: "FOR UPDATE"
          )

        repo = Repo.one!(from r in Repository, where: r.id == ^repository.id, lock: "FOR UPDATE")

        current = Uploads.lock_intent!(intent.id)

        reservation =
          current &&
            current.reservation_id &&
            Repo.one(
              from r in Reservation, where: r.id == ^current.reservation_id, lock: "FOR UPDATE"
            )

        initiator = Repo.get(User, intent.user_id)

        cond do
          is_nil(current) or current.status != "processing" or current.lease_token != token ->
            {:ok, {:lost, nil}}

          settings_changed?(repo, owner, sign_snapshot) ->
            {:ok, {:settings_changed, current}}

          sign_snapshot.sign_rpms and key_expired?(owner) ->
            {:ok, {:fail, "conflict_gpg_key_expired", current}}

          is_nil(initiator) or not (initiator.is_admin or initiator.id == repo.user_id) ->
            {:ok, {:fail, "forbidden", current}}

          match?({:error, _}, duplicate_check(repo.id, candidate_metadata(candidate))) ->
            {:ok, {:fail, "conflict_duplicate_package", current}}

          match?({:error, _}, check_limits(repo, candidate)) ->
            {:ok, {:fail, "conflict_repository_metadata_limit_exceeded", current}}

          is_nil(reservation) ->
            {:ok, {:fail, "conflict_upload_state", current}}

          expired_reservation_over_quota?(owner, reservation, candidate.size_package) ->
            {:ok, {:fail, "conflict_storage_quota_exceeded", current}}

          true ->
            insert_package_and_succeed!(owner, repo, current, reservation, candidate)
            {:ok, {:committed, current}}
        end
      end)

    case result do
      {:committed, _} ->
        :ok

      {:lost, _} ->
        _ = B2.delete_version(config, candidate.storage_path, candidate.storage_version_id)
        :ok

      {:settings_changed, current} ->
        _ = B2.delete_version(config, candidate.storage_path, candidate.storage_version_id)
        restore_and_requeue(current, token)

      {:fail, code, _current} ->
        _ = B2.delete_version(config, candidate.storage_path, candidate.storage_version_id)
        deterministic_failure(intent, token, code)
    end
  end

  # A signing-setting or fingerprint change while the attempt ran means the
  # candidate bytes were produced under superseded settings.
  defp settings_changed?(repo, owner, snapshot) do
    repo.sign_rpms != snapshot.sign_rpms or
      repo.gpg_key_fingerprint != snapshot.gpg_key_fingerprint or
      (snapshot.sign_rpms and
         (owner.gpg_signing_fingerprint != snapshot.owner_signing_fingerprint or
            owner.gpg_key_public != snapshot.owner_public_key))
  end

  defp key_expired?(%{gpg_key_expires_at: nil}), do: false

  defp key_expired?(%{gpg_key_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp candidate_metadata(candidate) do
    %{
      name: candidate.name,
      epoch: candidate.epoch,
      version: candidate.version,
      release: candidate.release,
      arch: candidate.arch
    }
  end

  # Before consuming an expired reservation, renew it subject to the quota.
  defp expired_reservation_over_quota?(owner, reservation, final_size) do
    now = DateTime.utc_now(:second)

    if DateTime.compare(reservation.expires_at, now) == :gt do
      false
    else
      max = Application.get_env(:dark_zenith, :max_user_storage_bytes, 53_687_091_200)
      others = Storage.active_reserved_bytes(owner.id)
      max > 0 and owner.storage_bytes + others + final_size > max
    end
  end

  defp insert_package_and_succeed!(owner, repo, intent, reservation, candidate) do
    now = DateTime.utc_now(:second)
    entry_sizes = Repodata.entry_open_sizes(candidate)
    overhead_now = Repodata.document_overhead(repo.package_count)
    overhead_next = Repodata.document_overhead(repo.package_count + 1)

    Repo.insert!(candidate)

    {1, _} =
      Repo.update_all(
        from(r in Repository, where: r.id == ^repo.id),
        inc: [
          package_count: 1,
          metadata_revision: 1,
          primary_open_bytes: entry_sizes.primary + overhead_next.primary - overhead_now.primary,
          filelists_open_bytes:
            entry_sizes.filelists + overhead_next.filelists - overhead_now.filelists,
          other_open_bytes: entry_sizes.other + overhead_next.other - overhead_now.other
        ]
      )

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^owner.id),
        inc: [storage_bytes: candidate.size_package]
      )

    {1, _} =
      Repo.update_all(
        from(i in Intent, where: i.id == ^intent.id),
        set: [
          status: "succeeded",
          reservation_id: nil,
          completed_at: now,
          lease_token: nil,
          lease_expires_at: nil,
          next_attempt_at: nil,
          last_error_code: nil,
          updated_at: now
        ]
      )

    Repo.delete!(reservation)

    Audit.record!("package.upload",
      actor: Repo.get(User, intent.user_id),
      target: {:package, candidate.id},
      metadata: %{
        "slug" => repo.slug,
        "nevra" =>
          "#{candidate.name}-#{candidate.epoch}:#{candidate.version}-#{candidate.release}." <>
            candidate.arch,
        "result" => "succeeded"
      }
    )

    Repodata.enqueue_regeneration(repo.id)
    Uploads.enqueue_staging_cleanup(intent.staging_path)
  end

  ## Web preview

  defp preview_transition(intent, token, metadata) do
    preview = Uploads.preview_metadata(metadata)
    now = DateTime.utc_now(:second)
    expires = DateTime.add(now, 15 * 60, :second)

    {:ok, result} =
      Repo.transact(fn ->
        current = Uploads.lock_intent!(intent.id)

        if current && current.status == "processing" && current.lease_token == token do
          {1, _} =
            Repo.update_all(
              from(i in Intent, where: i.id == ^intent.id),
              set: [
                status: "preview_ready",
                preview_metadata: preview,
                expires_at: expires,
                lease_token: nil,
                lease_expires_at: nil,
                last_error_code: nil,
                updated_at: now
              ]
            )

          {_count, _} =
            Repo.update_all(
              from(r in Reservation, where: r.id == ^current.reservation_id),
              set: [expires_at: expires, updated_at: now]
            )

          {:ok, :ok}
        else
          {:ok, :ok}
        end
      end)

    result
  end

  ## Failure paths

  defp deterministic_failure(intent, token, code) do
    {:ok, _} =
      Repo.transact(fn ->
        current = Uploads.lock_intent!(intent.id)

        if current && current.status == "processing" && current.lease_token == token do
          Uploads.terminalize!(current, "failed", code)

          Audit.record!("package.upload",
            actor: Repo.get(User, intent.user_id),
            target: {:upload_intent, intent.id},
            metadata: %{"result" => code}
          )
        end

        {:ok, :ok}
      end)

    :ok
  end

  defp infra_failure(intent, token, code) do
    now = DateTime.utc_now(:second)

    {:ok, action} =
      Repo.transact(fn ->
        current = Uploads.lock_intent!(intent.id)

        cond do
          is_nil(current) or current.status != "processing" or current.lease_token != token ->
            {:ok, :noop}

          current.attempts >= @max_attempts ->
            Uploads.terminalize!(current, "failed", code)

            Audit.record!("package.upload",
              actor: Repo.get(User, intent.user_id),
              target: {:upload_intent, intent.id},
              metadata: %{"result" => code}
            )

            {:ok, :noop}

          true ->
            next_at = DateTime.add(now, RetryPolicy.backoff(current.attempts), :second)

            {1, _} =
              Repo.update_all(
                from(i in Intent, where: i.id == ^intent.id),
                set: [
                  status: "queued",
                  lease_token: nil,
                  lease_expires_at: nil,
                  next_attempt_at: next_at,
                  last_error_code: code,
                  updated_at: now
                ]
              )

            {:ok, {:requeue, next_at}}
        end
      end)

    case action do
      {:requeue, next_at} -> Uploads.enqueue_processing(intent.id, next_at)
      :noop -> :ok
    end

    :ok
  end

  # The pre-claim attempt count is restored so a settings race does not
  # consume a retry; a fresh attempt uses current settings.
  defp restore_and_requeue(current, token) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.transact(fn ->
        locked = Uploads.lock_intent!(current.id)

        if locked && locked.status == "processing" && locked.lease_token == token do
          {1, _} =
            Repo.update_all(
              from(i in Intent, where: i.id == ^current.id),
              set: [
                status: "queued",
                lease_token: nil,
                lease_expires_at: nil,
                next_attempt_at: now,
                updated_at: now
              ],
              inc: [attempts: -1]
            )
        end

        {:ok, :ok}
      end)

    Uploads.enqueue_processing(current.id, now)
    :ok
  end

  defp temp_space do
    Application.get_env(:dark_zenith, :temp_space_server, DarkZenith.TempSpace)
  end

  defp max_repository_packages do
    Application.get_env(:dark_zenith, :max_repository_packages, 10_000)
  end

  defp max_repodata_open_bytes do
    Application.get_env(:dark_zenith, :max_repodata_open_bytes, 268_435_456)
  end
end
