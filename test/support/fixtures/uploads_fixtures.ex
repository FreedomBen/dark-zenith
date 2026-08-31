defmodule DarkZenith.UploadsFixtures do
  @moduledoc """
  Direct-insert helpers for upload intents and storage reservations, for
  tests that need rows in specific states without the full intent flow.
  """

  alias DarkZenith.Repo
  alias DarkZenith.Storage.Reservation
  alias DarkZenith.Uploads.Intent

  def reservation_row_fixture(user, repository, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      repository_id: repository.id,
      package_id: Ecto.UUID.generate(),
      kind: "upload",
      reserved_bytes: 1000,
      expires_at: DateTime.add(DateTime.utc_now(:second), 2, :hour)
    }

    Repo.insert!(struct(Reservation, Map.merge(defaults, Map.new(attrs))))
  end

  @doc "A valid `awaiting_upload` intent row linking the reservation."
  def awaiting_intent_row_fixture(repository, user, reservation, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    defaults = %{
      repository_id: repository.id,
      user_id: user.id,
      package_id: reservation.package_id,
      reservation_id: reservation.id,
      mode: "api",
      status: "awaiting_upload",
      original_filename: "fixture.rpm",
      declared_size: reservation.reserved_bytes,
      staging_path: "staging/uploads/#{Ecto.UUID.generate()}.rpm",
      upload_url_expires_at: DateTime.add(now, 1, :hour),
      expires_at: DateTime.add(now, 2, :hour)
    }

    Repo.insert!(struct(Intent, Map.merge(defaults, Map.new(attrs))))
  end
end
