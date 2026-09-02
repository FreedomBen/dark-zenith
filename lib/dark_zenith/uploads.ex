defmodule DarkZenith.Uploads do
  @moduledoc """
  Upload-intent lifecycle (DESIGN.md: Upload Intents): creation with the
  declared-size reservation and presigned staging URL, URL refresh with a
  fresh staging key, exact-version completion with the HeadObject contract
  check, cancellation, and the waiting/lease/terminal sweeps. Processing
  itself runs in `DarkZenith.Workers.UploadProcessing`.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit
  alias DarkZenith.Authorization
  alias DarkZenith.B2
  alias DarkZenith.Repo
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Storage
  alias DarkZenith.Uploads.{Intent, Record, Records}
  alias DarkZenith.Workers.{RetryPolicy, StagingCleanup, UploadProcessing}

  @waiting_seconds 2 * 3600
  @refresh_min_remaining 60

  ## Reads

  @doc "Fetches an intent by id scoped to a repository, or nil."
  def get_intent(%Repository{id: repository_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Intent, id: uuid, repository_id: repository_id)
      :error -> nil
    end
  end

  @doc """
  Fetches an intent by id scoped to a repository and to its initiator, or
  nil. Every id-addressed intent surface treats another user's intent as
  nonexistent (DESIGN.md: REST API — intent endpoints).
  """
  def get_intent_for(%User{id: user_id}, %Repository{} = repository, id) do
    case get_intent(repository, id) do
      %Intent{user_id: ^user_id} = intent -> intent
      _ -> nil
    end
  end

  @doc """
  The repository's Package Upload Records, `started_at` descending then
  `id` ascending, with `live_status` filled from any surviving intent.
  Options: `:outcomes`, `:page`, `:per_page`. Returns `{records, total}`.
  """
  def list_repository_records(%Repository{id: repository_id}, opts \\ []) do
    Records.list_repository_records(repository_id, opts)
  end

  @doc "The hourly anti-join finalizing `in_flight` records whose intent is gone."
  def reconcile_orphaned_records, do: Records.reconcile_orphans()

  @doc """
  The self-sufficient metadata every `package.upload*` audit event carries
  (DESIGN.md: Audit Events): repository id and slug, intent id, upload
  record id, and original filename, so any upload event resolves to its
  record and back.
  """
  def audit_metadata(%Intent{} = intent) do
    audit_metadata(intent, Records.get_by_intent(intent.id))
  end

  def audit_metadata(%Intent{} = intent, %Record{} = record) do
    %{
      "repository_id" => record.repository_id,
      "repository_slug" => record.repository_slug,
      "intent_id" => intent.id,
      "upload_record_id" => record.id,
      "original_filename" => intent.original_filename
    }
  end

  ## Creation

  @doc """
  Creates an upload intent: validates the display filename and declared
  size, reserves the declared size against the repository owner's quota,
  and returns the intent plus the ephemeral `upload` capability object.
  """
  def create_intent(%User{} = actor, %Repository{} = repository, attrs) do
    with :ok <- authorize(actor, repository),
         {:ok, mode} <- validate_mode(attrs[:mode] || attrs["mode"]),
         {:ok, filename} <- validate_filename(attrs[:filename] || attrs["filename"]),
         {:ok, size} <- validate_size(attrs[:size] || attrs["size"]) do
      owner = owner_of(actor, repository)
      package_id = Ecto.UUID.generate()
      staging_path = new_staging_path()
      now = DateTime.utc_now(:second)
      expires_at = DateTime.add(now, @waiting_seconds, :second)
      ttl = min(b2_upload_url_ttl(), @waiting_seconds)
      url_expires_at = DateTime.add(now, ttl, :second)

      result =
        Repo.transact(fn ->
          with :ok <- DarkZenith.SigningTransitions.check_owner_mutation(owner.id, :create),
               {:ok, reservation} <-
                 Storage.create_reservation(owner, repository.id, package_id, "upload", size) do
            intent =
              Repo.insert!(%Intent{
                repository_id: repository.id,
                user_id: actor.id,
                package_id: package_id,
                reservation_id: reservation.id,
                mode: mode,
                status: "awaiting_upload",
                original_filename: filename,
                declared_size: size,
                staging_path: staging_path,
                upload_url_expires_at: url_expires_at,
                expires_at: expires_at
              })

            record = Records.create_for_intent!(intent, repository.slug, actor.email)

            Audit.record!("package.upload_intent_create",
              actor: actor,
              target: {:upload_intent, intent.id},
              metadata:
                Map.merge(audit_metadata(intent, record), %{
                  "declared_size" => Integer.to_string(size),
                  "mode" => mode
                })
            )

            {:ok, intent}
          end
        end)

      with {:ok, intent} <- result do
        {:ok, intent, upload_capability(intent, ttl)}
      end
    end
  end

  ## Refresh

  @doc """
  Replaces an expired direct-transfer URL: only while `awaiting_upload`,
  after the current URL expired, with at least 60 seconds left before the
  intent expires. Increments the generation, swaps in a fresh random
  staging key, and schedules the abandoned key for cleanup.
  """
  def refresh_intent(%User{} = actor, %Intent{} = intent) do
    with :ok <- authorize_intent(actor, intent) do
      now = DateTime.utc_now(:second)

      result =
        Repo.transact(fn ->
          current = lock_intent!(intent.id)

          cond do
            is_nil(current) or current.status != "awaiting_upload" ->
              {:error, :upload_state}

            DateTime.compare(current.upload_url_expires_at, now) == :gt ->
              {:error, :upload_state}

            DateTime.diff(current.expires_at, now) < @refresh_min_remaining ->
              {:error, :upload_state}

            true ->
              ttl = min(b2_upload_url_ttl(), max(DateTime.diff(current.expires_at, now), 1))
              staging_path = new_staging_path()

              updated =
                current
                |> Ecto.Changeset.change(
                  upload_generation: current.upload_generation + 1,
                  staging_path: staging_path,
                  upload_url_expires_at: DateTime.add(now, ttl, :second)
                )
                |> Repo.update!()

              enqueue_staging_cleanup(current.staging_path)

              Audit.record!("package.upload_intent_refresh",
                actor: actor,
                target: {:upload_intent, current.id},
                metadata:
                  Map.put(
                    audit_metadata(current),
                    "generation",
                    Integer.to_string(updated.upload_generation)
                  )
              )

              {:ok, {updated, ttl}}
          end
        end)

      with {:ok, {updated, ttl}} <- result do
        {:ok, updated, upload_capability(updated, ttl)}
      end
    end
  end

  ## Completion

  @doc """
  Accepts the exact staged B2 version for the given upload generation after
  the HeadObject contract check, queuing processing. Idempotent for the
  already-accepted generation/version.
  """
  def complete_intent(%User{} = actor, %Intent{} = intent, generation, version_id) do
    with :ok <- authorize_intent(actor, intent),
         :ok <- validate_version_id(version_id),
         {:ok, current} <- classify_completion(actor, intent.id, generation, version_id) do
      case current do
        {:already, accepted} -> {:ok, accepted}
        {:verify, awaiting} -> verify_and_accept(actor, awaiting, generation, version_id)
      end
    end
  end

  defp classify_completion(actor, intent_id, generation, version_id) do
    {:ok, result} =
      Repo.transact(fn ->
        current = lock_intent!(intent_id)

        classification =
          cond do
            is_nil(current) ->
              {:error, :not_found}

            current.status in ["canceled", "expired"] ->
              {:error, :upload_state}

            current.status in ["queued", "processing", "preview_ready", "succeeded", "failed"] ->
              if current.staging_version_id == version_id and
                   current.upload_generation == generation do
                {:ok, {:already, current}}
              else
                {:error, :upload_state}
              end

            overdue?(current) ->
              # An overdue completion attempt expires the intent; the actor
              # who tried is recorded, unlike the sweep's system event.
              expire!(current, actor)
              {:error, :upload_state}

            current.upload_generation != generation ->
              {:error, :upload_state}

            true ->
              {:ok, {:verify, current}}
          end

        {:ok, classification}
      end)

    result
  end

  defp verify_and_accept(actor, intent, generation, version_id) do
    config = B2.config!()

    case B2.head_object(config, intent.staging_path, version_id) do
      {:ok, head} ->
        case B2.verify_object_contract(head, intent.declared_size) do
          :ok ->
            accept!(actor, intent, generation, version_id)

          {:error, _violation} ->
            # The mismatched version is permanently deleted; the intent keeps
            # awaiting a clean upload.
            _ = B2.delete_version(config, intent.staging_path, version_id)
            {:error, :validation_failed}
        end

      {:error, :not_found} ->
        {:error, :validation_failed}

      {:error, :storage_unavailable} ->
        {:error, :storage_unavailable}
    end
  end

  defp accept!(actor, intent, generation, version_id) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(i in Intent,
          where:
            i.id == ^intent.id and i.status == "awaiting_upload" and
              i.upload_generation == ^generation
        ),
        set: [
          status: "queued",
          staging_version_id: version_id,
          upload_url_expires_at: nil,
          expires_at: nil,
          next_attempt_at: now,
          updated_at: now
        ]
      )

    case count do
      1 ->
        enqueue_processing(intent.id, now)
        {:ok, Repo.get!(Intent, intent.id)}

      0 ->
        # Lost a race with another completion/cancel; reclassify once.
        with {:ok, {:already, accepted}} <-
               classify_completion(actor, intent.id, generation, version_id) do
          {:ok, accepted}
        end
    end
  end

  ## Cancellation

  @doc """
  Cancels an unfinished intent, releasing its reservation and staging.
  Repeating cancellation, or cancelling an already failed/expired intent,
  is an idempotent success; a succeeded intent conflicts (DESIGN.md:
  `DELETE /api/v1/repos/:slug/package-uploads/:id`).
  """
  def cancel_intent(%User{} = actor, %Intent{} = intent) do
    with :ok <- authorize_intent(actor, intent) do
      {:ok, result} =
        Repo.transact(fn ->
          current = lock_intent!(intent.id)

          cond do
            is_nil(current) ->
              {:ok, {:error, :not_found}}

            current.status in ["awaiting_upload", "queued", "processing", "preview_ready"] ->
              canceled = terminalize!(current, "canceled")

              Audit.record!("package.upload_intent_cancel",
                actor: actor,
                target: {:upload_intent, current.id},
                metadata: audit_metadata(current)
              )

              {:ok, {:ok, canceled}}

            current.status == "succeeded" ->
              {:ok, {:error, :upload_state}}

            true ->
              # canceled/failed/expired: already terminal, nothing to change.
              {:ok, {:ok, current}}
          end
        end)

      result
    end
  end

  ## Web preview confirmation

  @doc """
  Confirms a web preview: reauthorizes the same initiating user, returns the
  intent to `queued` with a fresh retry budget, renews the reservation two
  hours ahead, and runs a new processing attempt from B2.
  """
  def confirm_preview(%User{} = actor, %Intent{} = intent) do
    with :ok <- authorize_intent(actor, intent),
         :ok <- if(actor.id == intent.user_id, do: :ok, else: {:error, :forbidden}) do
      now = DateTime.utc_now(:second)

      {:ok, result} =
        Repo.transact(fn ->
          current = lock_intent!(intent.id)

          if current && current.status == "preview_ready" do
            {1, _} =
              Repo.update_all(
                from(i in Intent, where: i.id == ^intent.id),
                set: [
                  status: "queued",
                  attempts: 0,
                  next_attempt_at: now,
                  expires_at: nil,
                  last_error_code: nil,
                  last_error_detail: nil,
                  updated_at: now
                ]
              )

            Storage.renew_reservation(current.reservation_id)
            {:ok, {:ok, Repo.get!(Intent, intent.id)}}
          else
            {:ok, {:error, :upload_state}}
          end
        end)

      with {:ok, confirmed} <- result do
        enqueue_processing(confirmed.id, now)
        {:ok, confirmed}
      end
    end
  end

  @doc """
  The jsonb-safe preview metadata map built from parsed RPM metadata
  (DESIGN.md: Upload Intents `preview_metadata`), also used for the
  metadata-equality recheck after confirmation.
  """
  def preview_metadata(%DarkZenith.Rpm.Metadata{} = m) do
    %{
      "rpm_format" => m.rpm_format,
      "name" => m.name,
      "epoch" => m.epoch,
      "version" => m.version,
      "release" => m.release,
      "arch" => m.arch,
      "summary" => m.summary,
      "description" => m.description,
      "url" => m.url,
      "license" => m.license,
      "rpm_sourcerpm" => m.rpm_sourcerpm,
      "rpm_sourcenevr" => m.rpm_sourcenevr,
      "rpm_group" => m.rpm_group,
      "rpm_vendor" => m.rpm_vendor,
      "rpm_buildhost" => m.rpm_buildhost,
      "size_installed" => m.size_installed,
      "size_archive" => m.size_archive,
      "build_time" => m.build_time && DateTime.to_iso8601(m.build_time),
      "requires" => m.requires,
      "provides" => m.provides,
      "conflicts" => m.conflicts,
      "obsoletes" => m.obsoletes,
      "recommends" => m.recommends,
      "suggests" => m.suggests,
      "supplements" => m.supplements,
      "enhances" => m.enhances,
      "files" => m.files,
      "changelogs" => m.changelogs
    }
  end

  ## Sweeps

  @doc "Expires overdue awaiting_upload/preview_ready rows (15-minute sweep)."
  def expire_overdue do
    now = DateTime.utc_now(:second)

    ids =
      Repo.all(
        from i in Intent,
          where: i.status in ["awaiting_upload", "preview_ready"] and i.expires_at <= ^now,
          select: i.id
      )

    Enum.each(ids, fn id ->
      {:ok, _} =
        Repo.transact(fn ->
          current = lock_intent!(id)

          if current && current.status in ["awaiting_upload", "preview_ready"] &&
               overdue?(current) do
            # The sweep is a system actor: null actor fields and no client IP.
            expire!(current, nil)
          end

          {:ok, :ok}
        end)
    end)

    :ok
  end

  # Expires a waiting intent and records the terminal outcome (DESIGN.md:
  # Audit Events — the expiry event targets the intent).
  defp expire!(%Intent{} = intent, actor) do
    expired = terminalize!(intent, "expired")

    Audit.record!("package.upload",
      actor: actor,
      ip: if(actor, do: Audit.client_ip(), else: nil),
      target: {:upload_intent, intent.id},
      metadata: Map.put(audit_metadata(intent), "result", "expired")
    )

    expired
  end

  # Terminal failure from the sweep: the system actor records the same
  # `package.upload` event a worker would (DESIGN.md: Audit Events).
  defp exhaust!(%Intent{} = intent, code) do
    failed = terminalize!(intent, "failed", code)

    Audit.record!("package.upload",
      actor: nil,
      ip: nil,
      target: {:upload_intent, intent.id},
      metadata: Map.put(audit_metadata(intent), "result", code)
    )

    failed
  end

  @doc """
  Requeues processing rows whose lease expired and renews the storage
  reservations of queued/processing intents two hours ahead (60-second
  sweep). An expired lease is a failed claim with no classified cause: the
  intent returns to `queued` under Background Retry Policy, or fails
  terminally as `internal_error` when the expired claim was the last of
  its budget (DESIGN.md: Upload Intents).
  """
  def requeue_expired_leases do
    now = DateTime.utc_now(:second)

    expired_ids =
      Repo.all(
        from i in Intent,
          where: i.status == "processing" and i.lease_expires_at <= ^now,
          select: i.id
      )

    Enum.each(expired_ids, fn id ->
      {:ok, _} =
        Repo.transact(fn ->
          current = lock_intent!(id)

          cond do
            is_nil(current) or current.status != "processing" or
                DateTime.compare(current.lease_expires_at, now) == :gt ->
              :noop

            current.attempts >= RetryPolicy.max_attempts() ->
              exhaust!(current, "internal_error")

            true ->
              next_at =
                DateTime.add(now, RetryPolicy.backoff(max(current.attempts, 1)), :second)

              {1, _} =
                Repo.update_all(
                  from(i in Intent, where: i.id == ^id),
                  set: [
                    status: "queued",
                    lease_token: nil,
                    lease_expires_at: nil,
                    next_attempt_at: next_at,
                    updated_at: now
                  ]
                )

              enqueue_processing(id, next_at)
          end

          {:ok, :ok}
        end)
    end)

    reservation_ids =
      Repo.all(
        from i in Intent,
          where: i.status in ["queued", "processing"] and not is_nil(i.reservation_id),
          select: i.reservation_id
      )

    Enum.each(reservation_ids, &Storage.renew_reservation/1)
    :ok
  end

  @doc "Deletes terminal intent rows older than 24 hours (hourly sweep)."
  def delete_old_terminal do
    cutoff = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    Repo.delete_all(
      from i in Intent,
        where:
          i.status in ["succeeded", "failed", "expired", "canceled"] and
            i.completed_at <= ^cutoff
    )

    :ok
  end

  ## Shared helpers (also used by the processing worker)

  @doc false
  def enqueue_staging_cleanup(staging_path) do
    %{staging_path: staging_path}
    |> StagingCleanup.new()
    |> Oban.insert!()
  end

  @doc false
  def enqueue_processing(intent_id, scheduled_at) do
    %{intent_id: intent_id}
    |> UploadProcessing.new(scheduled_at: scheduled_at)
    |> Oban.insert!()
  end

  @doc false
  # Terminal transition inside a transaction holding the intent lock.
  def terminalize!(%Intent{} = intent, status, error_code \\ nil, error_detail \\ nil) do
    now = DateTime.utc_now(:second)

    fields = [
      status: status,
      reservation_id: nil,
      completed_at: now,
      next_attempt_at: nil,
      lease_token: nil,
      lease_expires_at: nil,
      expires_at: nil,
      upload_url_expires_at: nil,
      updated_at: now
    ]

    fields = if error_code, do: Keyword.put(fields, :last_error_code, error_code), else: fields

    fields =
      if error_detail, do: Keyword.put(fields, :last_error_detail, error_detail), else: fields

    {1, _} = Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: fields)

    # The durable record takes its one terminal write in this transaction.
    Records.finalize!(intent.id, status, error_code: error_code, error_detail: error_detail)

    if intent.reservation_id, do: Storage.release_reservation(intent.reservation_id)
    enqueue_staging_cleanup(intent.staging_path)

    Repo.get!(Intent, intent.id)
  end

  @doc """
  Extends a processing intent's execution lease under its fencing token;
  `:halt` means the claim was canceled or superseded and the worker must
  discard its attempt.
  """
  def renew_intent_lease(intent_id, token) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(i in Intent,
          where: i.id == ^intent_id and i.status == "processing" and i.lease_token == ^token
        ),
        set: [lease_expires_at: DateTime.add(now, 900, :second), updated_at: now]
      )

    if count == 1, do: :ok, else: :halt
  end

  @doc false
  def lock_intent!(id) do
    Repo.one(from i in Intent, where: i.id == ^id, lock: "FOR UPDATE")
  end

  ## Validation

  defp authorize(actor, repository) do
    if Authorization.can_manage?(actor, repository), do: :ok, else: {:error, :forbidden}
  end

  # Repository management access first, then the initiator-only rule: a
  # second manager's intent is treated as nonexistent (DESIGN.md: REST API).
  defp authorize_intent(actor, %Intent{} = intent) do
    repository = Repo.get!(Repository, intent.repository_id)

    with :ok <- authorize(actor, repository) do
      if actor.id == intent.user_id, do: :ok, else: {:error, :not_found}
    end
  end

  defp owner_of(actor, repository) do
    if actor.id == repository.user_id do
      actor
    else
      Repo.get!(User, repository.user_id)
    end
  end

  defp validate_mode(mode) when mode in ["api", "web_preview"], do: {:ok, mode}
  defp validate_mode(_mode), do: {:error, :invalid_mode}

  # The client filename is reduced to its final path component (both / and \
  # are separators) and is display-only.
  defp validate_filename(filename) when is_binary(filename) do
    final =
      filename
      |> String.split(~r{[/\\]})
      |> List.last()
      |> Kernel.||("")
      |> String.trim()

    valid? =
      final != "" and String.valid?(final) and String.length(final) <= 255 and
        not Enum.any?(String.to_charlist(final), &((&1 < 0x20 and &1 not in []) or &1 == 0x7F))

    if valid?, do: {:ok, final}, else: {:error, :invalid_filename}
  end

  defp validate_filename(_filename), do: {:error, :invalid_filename}

  defp validate_size(size) when is_integer(size) do
    cond do
      size <= 0 -> {:error, :invalid_size}
      size > max_rpm_upload_bytes() -> {:error, :payload_too_large}
      true -> {:ok, size}
    end
  end

  defp validate_size(_size), do: {:error, :invalid_size}

  # An opaque non-empty string of at most 1024 bytes with no (ASCII) control
  # characters (DESIGN.md: completion endpoint).
  defp validate_version_id(version_id)
       when is_binary(version_id) and byte_size(version_id) in 1..1024 do
    control? =
      version_id
      |> :binary.bin_to_list()
      |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))

    if control?, do: {:error, :validation_failed}, else: :ok
  end

  defp validate_version_id(_version_id), do: {:error, :validation_failed}

  defp overdue?(%Intent{expires_at: nil}), do: false

  defp overdue?(%Intent{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now(:second)) != :gt
  end

  # 128 bits of server entropy in the staging key.
  defp new_staging_path do
    "staging/uploads/" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".rpm"
  end

  defp upload_capability(%Intent{} = intent, ttl) do
    %{
      generation: intent.upload_generation,
      method: "PUT",
      url:
        B2.staging_upload_url(B2.config!(), intent.staging_path, intent.declared_size, ttl: ttl),
      headers: %{"Content-Type" => "application/x-rpm"},
      content_length: intent.declared_size,
      expires_at: intent.upload_url_expires_at
    }
  end

  defp max_rpm_upload_bytes do
    Application.get_env(:dark_zenith, :max_rpm_upload_bytes, 536_870_912)
  end

  defp b2_upload_url_ttl do
    Application.get_env(:dark_zenith, :b2_upload_url_ttl, 3600)
  end
end
