defmodule DarkZenith.Workers.SigningItem do
  @moduledoc """
  Re-signs one package for a signing transition (DESIGN.md: Signing
  Transition Items).

  Each claim is a clean native-tool attempt: it leases temporary space,
  downloads the exact snapshotted source version, revalidates it, re-signs
  a working copy with the target fingerprint (preserving v4/v6 format),
  verifies the output, reserves any positive size delta, uploads to a
  fresh final key, and commits a fenced compare-and-swap package update in
  the global lock order — enqueuing metadata regeneration plus deletion of
  the previous exact version atomically. Deterministic failures fail the
  item and transition; transient failures retry under Background Retry
  Policy with lease fencing throughout.
  """

  use Oban.Worker,
    queue: :rpm_processing,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:item_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.B2
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.SigningTransitions
  alias DarkZenith.SigningTransitions.{Item, Transition}
  alias DarkZenith.Storage
  alias DarkZenith.TempSpace
  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"item_id" => item_id}}) do
    case SigningTransitions.claim_item(item_id) do
      :skip ->
        :ok

      {:ok, item, transition, token} ->
        package = Repo.get(Package, item.package_id)

        cond do
          is_nil(package) or package.storage_path != item.expected_storage_path or
              package.storage_version_id != item.expected_storage_version_id ->
            # The package was deleted or replaced: the item is satisfied by
            # cancellation.
            SigningTransitions.cancel_claimed_item(item, token)

          transition.kind == "delete_signed_packages" ->
            delete_item(item, transition, token, package)

          true ->
            run_with_temp_space(item, transition, token, package)
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  defp run_with_temp_space(item, transition, token, package) do
    case TempSpace.acquire(temp_space(), token, package.size_package) do
      {:ok, dir} ->
        try do
          run(item, transition, token, package, dir)
        after
          TempSpace.release(temp_space(), token)
        end

      {:error, :upload_temp_space_unavailable} ->
        SigningTransitions.item_transient_failure(item, token, "upload_temp_space_unavailable")
    end
  end

  defp run(item, transition, token, package, dir) do
    config = B2.config!()
    owner = Repo.get(User, transition.user_id)
    source_path = Path.join(dir, "source.rpm")

    result =
      with :ok <- fingerprint_check(owner, transition),
           :ok <- download(config, item, source_path),
           :ok <- verify_source(source_path, dir),
           {:ok, metadata} <- parse(source_path),
           {:ok, signed_path} <- sign(owner, source_path, dir, metadata.rpm_format),
           {:ok, final} <- signed_values(signed_path, metadata),
           :ok <- reserve_delta(item, transition, package, final.size),
           {:ok, final_key} <- compose_key(package, item),
           {:ok, final_version} <- upload(config, final_key, final.path),
           :ok <- verify_final(config, final_key, final_version, final.size) do
        commit(item, transition, token, package, final, final_key, final_version, config)
      end

    case result do
      :ok -> :ok
      {:error, {:deterministic, code}} -> SigningTransitions.item_deterministic_failure(item, token, code)
      {:error, {:infra, code}} -> SigningTransitions.item_transient_failure(item, token, code)
    end
  end

  # Replacement is blocked while a repository is `signing`, so for the
  # enable kind the owner's signing key must still match the target.
  defp fingerprint_check(owner, transition) do
    if owner && owner.gpg_signing_fingerprint == transition.target_fingerprint do
      :ok
    else
      {:error, {:deterministic, "conflict_gpg_key_transition_in_progress"}}
    end
  end

  defp download(config, item, source_path) do
    case B2.download_to_file(
           config,
           item.expected_storage_path,
           item.expected_storage_version_id,
           source_path
         ) do
      :ok -> :ok
      {:error, _} -> {:error, {:infra, "storage_unavailable"}}
    end
  end

  defp verify_source(source_path, dir) do
    dbpath = Path.join(dir, "rpmdb")
    File.mkdir_p!(dbpath)
    rpmkeys = Application.get_env(:dark_zenith, :rpmkeys_path, "rpmkeys")

    try do
      {output, _status} =
        System.cmd(rpmkeys, ["--dbpath", dbpath, "--checksig", "--verbose", source_path],
          env: [{"LC_ALL", "C"}],
          stderr_to_stdout: true
        )

      if output =~ "digest: OK" and not (output =~ " BAD") do
        :ok
      else
        {:error, {:deterministic, "validation_failed"}}
      end
    rescue
      ErlangError -> {:error, {:infra, "rpm_verification_unavailable"}}
    end
  end

  defp parse(source_path) do
    case DarkZenith.Rpm.parse(File.read!(source_path)) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, _} -> {:error, {:deterministic, "validation_failed"}}
    end
  end

  defp sign(owner, source_path, dir, format) do
    case DarkZenith.Signing.sign_rpm(owner, source_path, dir, format) do
      {:ok, signed_path} -> {:ok, signed_path}
      {:error, :expired} -> {:error, {:deterministic, "conflict_gpg_key_expired"}}
      {:error, :validation_failed} -> {:error, {:deterministic, "validation_failed"}}
      {:error, :rpm_verification_unavailable} -> {:error, {:infra, "rpm_verification_unavailable"}}
      {:error, _} -> {:error, {:infra, "signing_unavailable"}}
    end
  end

  defp signed_values(signed_path, _metadata) do
    %{size: size} = File.stat!(signed_path)
    max = Application.get_env(:dark_zenith, :max_rpm_upload_bytes, 536_870_912)

    cond do
      size > max ->
        {:error, {:deterministic, "payload_too_large"}}

      true ->
        case DarkZenith.Rpm.parse(File.read!(signed_path)) do
          {:ok, signed_metadata} ->
            {:ok,
             %{
               path: signed_path,
               size: size,
               sha256: sha256_file(signed_path),
               header_start: signed_metadata.header_start,
               header_end: signed_metadata.header_end,
               size_archive: signed_metadata.size_archive
             }}

          {:error, _} ->
            {:error, {:deterministic, "validation_failed"}}
        end
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # A positive size delta creates or adjusts the item's linked reservation;
  # a non-positive delta releases any linked row.
  defp reserve_delta(item, transition, package, final_size) do
    delta = final_size - package.size_package

    cond do
      delta <= 0 ->
        if item.reservation_id do
          Storage.release_reservation(item.reservation_id)
          clear_item_reservation(item)
        end

        :ok

      item.reservation_id ->
        case Storage.adjust_reservation(item.reservation_id, delta) do
          {:ok, _} -> :ok
          {:error, :quota_exceeded} -> {:error, {:deterministic, "conflict_storage_quota_exceeded"}}
          {:error, :not_found} -> create_item_reservation(item, transition, package, delta)
        end

      true ->
        create_item_reservation(item, transition, package, delta)
    end
  end

  defp create_item_reservation(item, transition, package, delta) do
    owner = Repo.get!(User, transition.user_id)

    case Storage.create_reservation(owner, package.repository_id, package.id, "resign", delta) do
      {:ok, reservation} ->
        {_count, _} =
          Repo.update_all(
            from(i in Item, where: i.id == ^item.id),
            set: [reservation_id: reservation.id, updated_at: DateTime.utc_now(:second)]
          )

        :ok

      {:error, :quota_exceeded} ->
        {:error, {:deterministic, "conflict_storage_quota_exceeded"}}
    end
  end

  defp clear_item_reservation(item) do
    {_count, _} =
      Repo.update_all(
        from(i in Item, where: i.id == ^item.id),
        set: [reservation_id: nil, updated_at: DateTime.utc_now(:second)]
      )
  end

  defp compose_key(package, item) do
    repository = Repo.get(Repository, item.repository_id)

    if repository do
      write_id = Ecto.UUID.generate()

      key =
        "repos/#{repository.slug}/packages/#{package.id}/#{write_id}/" <>
          "#{package.name}-#{package.epoch}-#{package.version}-#{package.release}." <>
          "#{package.arch}.rpm"

      {:ok, key}
    else
      {:error, {:deterministic, "validation_failed"}}
    end
  end

  defp upload(config, final_key, signed_path) do
    case B2.put_object(config, final_key, File.read!(signed_path)) do
      {:ok, version} -> {:ok, version}
      {:error, _} -> {:error, {:infra, "storage_unavailable"}}
    end
  end

  defp verify_final(config, final_key, final_version, final_size) do
    case B2.head_object(config, final_key, final_version) do
      {:ok, head} ->
        case B2.verify_object_contract(head, final_size) do
          :ok ->
            :ok

          {:error, _} ->
            _ = B2.delete_version(config, final_key, final_version)
            {:error, {:infra, "storage_unavailable"}}
        end

      {:error, _} ->
        {:error, {:infra, "storage_unavailable"}}
    end
  end

  ## The fenced compare-and-swap package update

  defp commit(item, transition, token, package, final, final_key, final_version, config) do
    {:ok, result} =
      Repo.transact(fn ->
        owner =
          Repo.one!(from u in User, where: u.id == ^transition.user_id, lock: "FOR UPDATE")

        repository =
          Repo.one(
            from r in Repository, where: r.id == ^item.repository_id, lock: "FOR UPDATE"
          )

        current_package =
          Repo.one(from p in Package, where: p.id == ^package.id, lock: "FOR UPDATE")

        current_transition =
          Repo.one!(from t in Transition, where: t.id == ^transition.id, lock: "FOR UPDATE")

        current_item = Repo.one!(from i in Item, where: i.id == ^item.id, lock: "FOR UPDATE")

        cond do
          current_item.status != "executing" or current_item.lease_token != token ->
            {:ok, :lost}

          is_nil(repository) or is_nil(current_package) or
            current_package.storage_path != item.expected_storage_path or
              current_package.storage_version_id != item.expected_storage_version_id ->
            {:ok, {:cancel_item, current_item}}

          not transition_still_valid?(current_transition, repository, owner) ->
            {:ok, {:fail, "conflict_gpg_key_transition_in_progress", current_item}}

          current_transition.kind == "enable_rpm_signing" and
              SigningTransitions.check_owner_mutation(owner.id, :create) != :ok ->
            {:ok, {:fence_deferred, current_item}}

          over_metadata_limit?(repository, current_package, final) ->
            {:ok, {:fail, "conflict_repository_metadata_limit_exceeded", current_item}}

          true ->
            apply_commit!(owner, repository, current_package, current_item, final, final_key, final_version)
            {:ok, :committed}
        end
      end)

    case result do
      :committed ->
        SigningTransitions.check_completion(transition.id)
        :ok

      :lost ->
        _ = B2.delete_version(config, final_key, final_version)
        :ok

      {:cancel_item, current_item} ->
        _ = B2.delete_version(config, final_key, final_version)
        SigningTransitions.cancel_claimed_item(current_item, token)
        :ok

      {:fence_deferred, current_item} ->
        _ = B2.delete_version(config, final_key, final_version)
        SigningTransitions.defer_item(current_item, token)
        :ok

      {:fail, code, _current_item} ->
        _ = B2.delete_version(config, final_key, final_version)
        SigningTransitions.item_deterministic_failure(item, token, code)
        :ok
    end
  end

  defp transition_still_valid?(%{kind: "enable_rpm_signing"} = transition, repository, owner) do
    transition.status in ["active", "failed"] and repository.sign_rpms and
      repository.signing_transition_id == transition.id and
      owner.gpg_signing_fingerprint == transition.target_fingerprint and
      not key_expired?(owner)
  end

  # Replacement items require the swapped key to still match the target.
  defp transition_still_valid?(%{kind: "replace_gpg_key"} = transition, repository, owner) do
    transition.status in ["active", "failed"] and repository.sign_rpms and
      owner.gpg_signing_fingerprint == transition.target_fingerprint and
      not key_expired?(owner)
  end

  defp transition_still_valid?(_transition, _repository, _owner), do: false

  defp key_expired?(%{gpg_key_expires_at: nil}), do: false

  defp key_expired?(%{gpg_key_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp over_metadata_limit?(repository, package, final) do
    old = Repodata.entry_open_sizes(package)

    new =
      Repodata.entry_open_sizes(%{
        package
        | sha256: final.sha256,
          size_package: final.size,
          size_archive: final.size_archive,
          header_start: final.header_start,
          header_end: final.header_end
      })

    limit = Application.get_env(:dark_zenith, :max_repodata_open_bytes, 268_435_456)

    repository.primary_open_bytes + new.primary - old.primary > limit or
      repository.filelists_open_bytes + new.filelists - old.filelists > limit or
      repository.other_open_bytes + new.other - old.other > limit
  end

  defp apply_commit!(owner, repository, package, item, final, final_key, final_version) do
    now = DateTime.utc_now(:second)
    old_sizes = Repodata.entry_open_sizes(package)
    size_delta = final.size - package.size_package

    {1, _} =
      Repo.update_all(
        from(p in Package,
          where:
            p.id == ^package.id and p.storage_path == ^package.storage_path and
              p.storage_version_id == ^package.storage_version_id
        ),
        set: [
          storage_path: final_key,
          storage_version_id: final_version,
          sha256: final.sha256,
          size_package: final.size,
          size_archive: final.size_archive,
          header_start: final.header_start,
          header_end: final.header_end,
          updated_at: now
        ]
      )

    updated_package = Repo.get!(Package, package.id)
    new_sizes = Repodata.entry_open_sizes(updated_package)

    {1, _} =
      Repo.update_all(
        from(r in Repository, where: r.id == ^repository.id),
        inc: [
          metadata_revision: 1,
          primary_open_bytes: new_sizes.primary - old_sizes.primary,
          filelists_open_bytes: new_sizes.filelists - old_sizes.filelists,
          other_open_bytes: new_sizes.other - old_sizes.other
        ]
      )

    if size_delta != 0 do
      {1, _} =
        Repo.update_all(
          from(u in User, where: u.id == ^owner.id),
          inc: [storage_bytes: size_delta]
        )
    end

    if item.reservation_id do
      Repo.delete_all(
        from r in DarkZenith.Storage.Reservation, where: r.id == ^item.reservation_id
      )
    end

    {1, _} =
      Repo.update_all(
        from(i in Item, where: i.id == ^item.id),
        set: [
          status: "succeeded",
          reservation_id: nil,
          lease_token: nil,
          lease_expires_at: nil,
          last_error_code: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    Repodata.enqueue_regeneration(repository.id)

    %{storage_path: package.storage_path, version_id: package.storage_version_id}
    |> DarkZenith.Workers.FinalVersionCleanup.new()
    |> Oban.insert!()
  end

  ## delete_signed_packages items (DESIGN.md: Signing Transition Items)

  # No download, temporary-space lease, or RPM/GPG work: one fenced
  # transaction applies the standard package deletion or cancels on a
  # missing/mismatched package.
  defp delete_item(item, transition, token, package) do
    {:ok, result} =
      Repo.transact(fn ->
        owner =
          Repo.one(from u in User, where: u.id == ^transition.user_id, lock: "FOR UPDATE")

        repository =
          Repo.one(
            from r in Repository, where: r.id == ^item.repository_id, lock: "FOR UPDATE"
          )

        current_package =
          Repo.one(from p in Package, where: p.id == ^package.id, lock: "FOR UPDATE")

        current_item = Repo.one!(from i in Item, where: i.id == ^item.id, lock: "FOR UPDATE")

        cond do
          current_item.status != "executing" or current_item.lease_token != token ->
            {:ok, :lost}

          is_nil(owner) or is_nil(repository) or is_nil(current_package) or
            current_package.storage_path != item.expected_storage_path or
              current_package.storage_version_id != item.expected_storage_version_id ->
            {:ok, {:cancel_item, current_item}}

          true ->
            apply_delete_commit!(owner, repository, current_package, current_item)
            {:ok, :committed}
        end
      end)

    case result do
      :committed ->
        SigningTransitions.check_completion(transition.id)
        :ok

      :lost ->
        :ok

      {:cancel_item, current_item} ->
        SigningTransitions.cancel_claimed_item(current_item, token)
        :ok
    end
  end

  defp apply_delete_commit!(owner, repository, package, item) do
    now = DateTime.utc_now(:second)
    entry_sizes = Repodata.entry_open_sizes(package)
    overhead_now = Repodata.document_overhead(repository.package_count)
    overhead_next = Repodata.document_overhead(repository.package_count - 1)

    Repo.delete!(package)

    {1, _} =
      Repo.update_all(
        from(r in Repository, where: r.id == ^repository.id),
        inc: [
          package_count: -1,
          metadata_revision: 1,
          primary_open_bytes: -entry_sizes.primary + overhead_next.primary - overhead_now.primary,
          filelists_open_bytes:
            -entry_sizes.filelists + overhead_next.filelists - overhead_now.filelists,
          other_open_bytes: -entry_sizes.other + overhead_next.other - overhead_now.other
        ]
      )

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^owner.id),
        inc: [storage_bytes: -package.size_package]
      )

    {1, _} =
      Repo.update_all(
        from(i in Item, where: i.id == ^item.id),
        set: [
          status: "succeeded",
          reservation_id: nil,
          lease_token: nil,
          lease_expires_at: nil,
          last_error_code: nil,
          completed_at: now,
          updated_at: now
        ]
      )

    Repodata.enqueue_regeneration(repository.id)

    %{storage_path: package.storage_path, version_id: package.storage_version_id}
    |> DarkZenith.Workers.FinalVersionCleanup.new()
    |> Oban.insert!()
  end

  defp temp_space do
    Application.get_env(:dark_zenith, :temp_space_server, DarkZenith.TempSpace)
  end
end
