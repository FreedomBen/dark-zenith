defmodule DarkZenithWeb.Api.V1.CollaboratorJSON do
  @moduledoc """
  Typed collaborator/invitation rows (DESIGN.md: API Contract Details —
  collaborator listing shapes). Bigint generations are decimal strings.
  """

  alias DarkZenith.Collaborators.{Collaborator, Invitation}

  def row(%Collaborator{} = collaborator) do
    %{
      "type" => "collaborator",
      "id" => collaborator.id,
      "user_id" => collaborator.user_id,
      "email" => collaborator.user.email,
      "notification_status" => collaborator.notification_status,
      "notification_generation" => Integer.to_string(collaborator.notification_generation),
      "notification_sent_at" => maybe_iso8601(collaborator.notification_sent_at),
      "inserted_at" => DateTime.to_iso8601(collaborator.inserted_at),
      "updated_at" => DateTime.to_iso8601(collaborator.updated_at)
    }
  end

  def row(%Invitation{} = invitation) do
    %{
      "type" => "invitation",
      "id" => invitation.id,
      "email" => invitation.email,
      "invited_by_id" => invitation.invited_by_id,
      "expires_at" => maybe_iso8601(invitation.expires_at),
      "notification_status" => invitation.notification_status,
      "notification_generation" => Integer.to_string(invitation.notification_generation),
      "notification_sent_at" => maybe_iso8601(invitation.notification_sent_at),
      "inserted_at" => DateTime.to_iso8601(invitation.inserted_at),
      "updated_at" => DateTime.to_iso8601(invitation.updated_at)
    }
  end

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
