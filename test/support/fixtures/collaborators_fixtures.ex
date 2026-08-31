defmodule DarkZenith.CollaboratorsFixtures do
  @moduledoc """
  Test helpers for collaborator and invitation rows.

  Direct-insert helpers bypass the context so schema/constraint tests and
  authorization-matrix tests do not depend on the add flow under test.
  """

  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Repo

  def unique_invited_email, do: "invitee#{System.unique_integer([:positive])}@example.com"

  def collaborator_row_fixture(repository, user, attrs \\ %{}) do
    defaults = %{
      repository_id: repository.id,
      user_id: user.id,
      notification_status: "queued",
      notification_generation: 1,
      notification_sent_at: nil
    }

    Repo.insert!(struct(Collaborator, Map.merge(defaults, Map.new(attrs))))
  end

  def invitation_row_fixture(repository, invited_by, attrs \\ %{}) do
    defaults = %{
      repository_id: repository.id,
      email: unique_invited_email(),
      invited_by_id: invited_by.id,
      expires_at: DateTime.add(DateTime.utc_now(:second), 30, :day),
      notification_status: "queued",
      notification_generation: 1,
      notification_sent_at: nil
    }

    Repo.insert!(struct(Invitation, Map.merge(defaults, Map.new(attrs))))
  end
end
