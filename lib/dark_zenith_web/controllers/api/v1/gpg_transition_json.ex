defmodule DarkZenithWeb.Api.V1.GpgTransitionJson do
  @moduledoc """
  The user-wide GPG transition resource (DESIGN.md: API Contract Details).
  Counts reflect durable snapshot/item rows available so far; candidate key
  material and preparation cursors are never exposed.
  """

  alias DarkZenith.SigningTransitions
  alias DarkZenithWeb.Api.Errors

  def render(transition) do
    repository_counts = SigningTransitions.repository_counts(transition.id)
    item_counts = SigningTransitions.item_counts(transition.id)
    item_total = item_counts |> Map.values() |> Enum.sum()
    repository_total = repository_counts |> Map.values() |> Enum.sum()

    %{
      "id" => transition.id,
      "kind" => transition.kind,
      "status" => transition.status,
      "resume_status" => transition.resume_status,
      "target_fingerprint" => transition.target_fingerprint,
      "phase_attempts" => transition.phase_attempts,
      "phase_next_attempt_at" => iso(transition.phase_next_attempt_at),
      "repositories_preparation_complete" => transition.repositories_preparation_complete,
      "packages_preparation_complete" => transition.packages_preparation_complete,
      "repository_count" => Integer.to_string(repository_total),
      "repository_applied_count" => Integer.to_string(repository_counts["applied"]),
      "repository_satisfied_deleted_count" =>
        Integer.to_string(repository_counts["satisfied_deleted"]),
      "item_count" => Integer.to_string(item_total),
      "pending_count" => Integer.to_string(item_counts["pending"]),
      "executing_count" => Integer.to_string(item_counts["executing"]),
      "succeeded_count" => Integer.to_string(item_counts["succeeded"]),
      "failed_count" => Integer.to_string(item_counts["failed"]),
      "canceled_count" => Integer.to_string(item_counts["canceled"]),
      "error" => error(transition),
      "inserted_at" => iso(transition.inserted_at),
      "updated_at" => iso(transition.updated_at),
      "completed_at" => iso(transition.completed_at)
    }
  end

  defp error(%{status: "failed", last_error_code: code}) when is_binary(code) do
    %{"code" => code, "message" => Errors.message(code)}
  end

  defp error(_transition), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
