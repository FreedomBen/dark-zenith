defmodule DarkZenith.StorageTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.UploadsFixtures

  alias DarkZenith.Storage
  alias DarkZenith.Storage.Reservation

  @default_max 53_687_091_200

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp set_storage_bytes!(user, bytes) do
    {1, _} =
      Repo.update_all(from(u in DarkZenith.Accounts.User, where: u.id == ^user.id),
        set: [storage_bytes: bytes]
      )

    %{user | storage_bytes: bytes}
  end

  describe "create_reservation/5" do
    test "creates a two-hour reservation", ctx do
      assert {:ok, %Reservation{} = reservation} =
               Storage.create_reservation(ctx.owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 500)

      assert reservation.reserved_bytes == 500
      assert reservation.kind == "upload"

      expected = DateTime.add(DateTime.utc_now(:second), 2, :hour)
      assert_in_delta DateTime.to_unix(reservation.expires_at), DateTime.to_unix(expected), 5
    end

    test "checks stored plus actively reserved bytes against the quota", ctx do
      owner = set_storage_bytes!(ctx.owner, @default_max - 100)

      assert {:ok, _} =
               Storage.create_reservation(owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 60)

      # 60 active + 41 requested crosses the remaining 100.
      assert {:error, :quota_exceeded} =
               Storage.create_reservation(owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 41)

      assert {:ok, _} =
               Storage.create_reservation(owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 40)
    end

    test "reclaims the user's expired unlinked reservations", ctx do
      owner = set_storage_bytes!(ctx.owner, @default_max - 100)

      expired =
        reservation_row_fixture(owner, ctx.repo, %{
          reserved_bytes: 80,
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
        })

      assert {:ok, _} =
               Storage.create_reservation(owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 90)

      refute Repo.get(Reservation, expired.id)
    end

    test "an expired reservation still linked by an intent is not reclaimed", ctx do
      linked =
        reservation_row_fixture(ctx.owner, ctx.repo, %{
          expires_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
        })

      awaiting_intent_row_fixture(ctx.repo, ctx.owner, linked)

      assert {:ok, _} =
               Storage.create_reservation(ctx.owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 10)

      assert Repo.get(Reservation, linked.id)
    end
  end

  describe "adjust_reservation/2" do
    test "shrinks always and grows only within the quota", ctx do
      owner = set_storage_bytes!(ctx.owner, @default_max - 100)

      {:ok, reservation} =
        Storage.create_reservation(owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 50)

      assert {:ok, %Reservation{reserved_bytes: 30}} =
               Storage.adjust_reservation(reservation.id, 30)

      assert {:ok, %Reservation{reserved_bytes: 100}} =
               Storage.adjust_reservation(reservation.id, 100)

      assert {:error, :quota_exceeded} = Storage.adjust_reservation(reservation.id, 101)
      assert Repo.get!(Reservation, reservation.id).reserved_bytes == 100
    end

    test "a missing reservation is reported", ctx do
      _ = ctx
      assert {:error, :not_found} = Storage.adjust_reservation(Ecto.UUID.generate(), 10)
    end
  end

  describe "renew and release" do
    test "renewal extends the lease two hours ahead", ctx do
      {:ok, reservation} =
        Storage.create_reservation(ctx.owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 10)

      past = DateTime.add(DateTime.utc_now(:second), -10, :minute)
      Repo.update_all(from(r in Reservation, where: r.id == ^reservation.id), set: [expires_at: past])

      assert :ok = Storage.renew_reservation(reservation.id)

      renewed = Repo.get!(Reservation, reservation.id)
      expected = DateTime.add(DateTime.utc_now(:second), 2, :hour)
      assert_in_delta DateTime.to_unix(renewed.expires_at), DateTime.to_unix(expected), 5
    end

    test "release deletes the row", ctx do
      {:ok, reservation} =
        Storage.create_reservation(ctx.owner, ctx.repo.id, Ecto.UUID.generate(), "upload", 10)

      assert :ok = Storage.release_reservation(reservation.id)
      refute Repo.get(Reservation, reservation.id)
      # Releasing again is harmless.
      assert :ok = Storage.release_reservation(reservation.id)
    end
  end

  describe "cleanup_expired/0" do
    test "removes only expired reservations that nothing links", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

      expired = reservation_row_fixture(ctx.owner, ctx.repo, %{expires_at: past})
      live = reservation_row_fixture(ctx.owner, ctx.repo)
      linked = reservation_row_fixture(ctx.owner, ctx.repo, %{expires_at: past})
      awaiting_intent_row_fixture(ctx.repo, ctx.owner, linked)

      Storage.cleanup_expired()

      refute Repo.get(Reservation, expired.id)
      assert Repo.get(Reservation, live.id)
      assert Repo.get(Reservation, linked.id)
    end
  end
end

defmodule DarkZenith.StorageQuotaDisabledTest do
  # Not async: overrides the global max_user_storage_bytes setting.
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Storage

  test "zero disables the ceiling but reservations are still tracked" do
    previous = Application.get_env(:dark_zenith, :max_user_storage_bytes)
    Application.put_env(:dark_zenith, :max_user_storage_bytes, 0)
    on_exit(fn -> Application.put_env(:dark_zenith, :max_user_storage_bytes, previous) end)

    owner = user_fixture()
    repo = repository_fixture(owner)

    {1, _} =
      Repo.update_all(from(u in DarkZenith.Accounts.User, where: u.id == ^owner.id),
        set: [storage_bytes: 999_999_999_999_999]
      )

    assert {:ok, reservation} =
             Storage.create_reservation(owner, repo.id, Ecto.UUID.generate(), "upload", 1_000_000)

    assert Storage.active_reserved_bytes(owner.id) == 1_000_000
    assert {:ok, _} = Storage.adjust_reservation(reservation.id, 2_000_000)
  end
end
