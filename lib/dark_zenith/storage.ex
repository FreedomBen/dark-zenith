defmodule DarkZenith.Storage do
  @moduledoc """
  Storage-reservation accounting (DESIGN.md: Storage Reservations).

  Reservations serialize per-owner quota checks under the user-row lock
  without holding database locks during object-storage I/O. The quota check
  is `users.storage_bytes + active reserved bytes + requested` against
  `MAX_USER_STORAGE_BYTES`; `0` disables the ceiling while accounting
  continues. Expired rows are reclaimed only when nothing links them.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo
  alias DarkZenith.Storage.Reservation
  alias DarkZenith.Uploads.Intent

  @lease_seconds 2 * 3600

  @doc """
  Creates a reservation for `bytes` under the owner's quota lock, first
  reclaiming the owner's expired unlinked reservations.
  """
  def create_reservation(%User{} = owner, repository_id, package_id, kind, bytes)
      when bytes > 0 do
    Repo.transact(fn ->
      lock_user_row!(owner.id)
      reclaim_expired_unlinked(owner.id)

      stored = Repo.one!(from u in User, where: u.id == ^owner.id, select: u.storage_bytes)

      with :ok <- check_quota(stored, active_reserved_bytes(owner.id), bytes) do
        {:ok,
         Repo.insert!(%Reservation{
           user_id: owner.id,
           repository_id: repository_id,
           package_id: package_id,
           kind: kind,
           reserved_bytes: bytes,
           expires_at: lease_expiry()
         })}
      end
    end)
  end

  @doc """
  Atomically changes a reservation to the exact byte count under the owner's
  quota lock. A decrease always succeeds; an increase requires remaining
  quota. Renews the lease.
  """
  def adjust_reservation(reservation_id, new_bytes) when new_bytes > 0 do
    Repo.transact(fn ->
      case Repo.get(Reservation, reservation_id) do
        nil ->
          {:error, :not_found}

        %Reservation{} = reservation ->
          lock_user_row!(reservation.user_id)
          reservation = Repo.get!(Reservation, reservation.id)

          stored =
            Repo.one!(
              from u in User, where: u.id == ^reservation.user_id, select: u.storage_bytes
            )

          other_active = active_reserved_bytes(reservation.user_id) - reservation.reserved_bytes

          with :ok <- check_quota(stored, max(other_active, 0), new_bytes) do
            {:ok,
             reservation
             |> Ecto.Changeset.change(reserved_bytes: new_bytes, expires_at: lease_expiry())
             |> Repo.update!()}
          end
      end
    end)
  end

  @doc "Renews a reservation's lease two hours ahead."
  def renew_reservation(reservation_id) do
    {_count, _} =
      Repo.update_all(
        from(r in Reservation, where: r.id == ^reservation_id),
        set: [expires_at: lease_expiry(), updated_at: DateTime.utc_now(:second)]
      )

    :ok
  end

  @doc "Releases (deletes) a reservation. Idempotent."
  def release_reservation(reservation_id) do
    Repo.delete_all(from(r in Reservation, where: r.id == ^reservation_id))
    :ok
  end

  @doc "Sum of the user's unexpired reserved bytes."
  def active_reserved_bytes(user_id) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from(r in Reservation,
        where: r.user_id == ^user_id and r.expires_at > ^now,
        select: type(coalesce(sum(r.reserved_bytes), 0), :integer)
      )
    )
  end

  @doc """
  Deletes expired reservations that no upload intent links (hourly cleanup;
  nonterminal signing items join the guard with the signing phase). Terminal
  intents null their reservation reference, so any link marks the row live.
  """
  def cleanup_expired do
    now = DateTime.utc_now(:second)

    Repo.delete_all(
      from(r in Reservation,
        as: :reservation,
        where: r.expires_at <= ^now,
        where: not exists(from i in Intent, where: i.reservation_id == parent_as(:reservation).id)
      )
    )

    :ok
  end

  defp reclaim_expired_unlinked(user_id) do
    now = DateTime.utc_now(:second)

    Repo.delete_all(
      from(r in Reservation,
        as: :reservation,
        where: r.user_id == ^user_id and r.expires_at <= ^now,
        where: not exists(from i in Intent, where: i.reservation_id == parent_as(:reservation).id)
      )
    )
  end

  defp check_quota(stored, active, requested) do
    max = max_user_storage_bytes()

    if max > 0 and stored + active + requested > max do
      {:error, :quota_exceeded}
    else
      :ok
    end
  end

  defp lease_expiry do
    DateTime.add(DateTime.utc_now(:second), @lease_seconds, :second)
  end

  defp max_user_storage_bytes do
    Application.get_env(:dark_zenith, :max_user_storage_bytes, 53_687_091_200)
  end

  defp lock_user_row!(user_id) do
    Repo.one!(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.id))
  end
end
