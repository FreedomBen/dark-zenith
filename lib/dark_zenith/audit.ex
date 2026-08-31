defmodule DarkZenith.Audit do
  @moduledoc """
  Append-only audit log of security-relevant actions (DESIGN.md: Audit Events).

  Rows are written in the same database transaction as the action they record
  when one exists; call `record!/2` inside that transaction. Application code
  never updates or deletes audit rows — the one mutation is the database
  clearing `actor_id` through `ON DELETE SET NULL` when the actor's account is
  deleted, while `actor_email` keeps attribution.
  """

  import Ecto.Query

  alias DarkZenith.Accounts.User
  alias DarkZenith.Audit.Event
  alias DarkZenith.Repo

  @doc """
  Records one audit event. Options:

    * `:actor` — the acting `%User{}`, or nil for unauthenticated/system events
    * `:target` — `{type, id}` with type an atom/string from the allowed target
      types, or a bare type for string-keyed targets (`:slug` uses metadata)
    * `:ip` — client IP string as resolved by client IP detection, nil for
      system events
    * `:metadata` — map of event-specific details; never secrets, token
      values, or key material
  """
  def record!(action, opts \\ []) when is_binary(action) do
    {target_type, target_id} =
      case Keyword.get(opts, :target) do
        nil -> {nil, nil}
        {type, id} -> {to_string(type), id}
        type when is_atom(type) or is_binary(type) -> {to_string(type), nil}
      end

    {actor_id, actor_email} =
      case Keyword.get(opts, :actor) do
        %User{id: id, email: email} -> {id, email}
        nil -> {nil, nil}
      end

    Repo.insert!(%Event{
      actor_id: actor_id,
      actor_email: actor_email,
      action: action,
      target_type: target_type,
      target_id: target_id,
      ip: Keyword.get(opts, :ip),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @doc """
  Lists audit events, newest first. Options: `:limit` (default 100),
  `:action` (prefix match), `:actor_email` (exact), `:target_type`.
  """
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    base =
      from event in Event,
        order_by: [desc: event.inserted_at, desc: event.id],
        limit: ^limit

    base
    |> filter_prefix(:action, opts[:action])
    |> filter_eq(:actor_email, opts[:actor_email])
    |> filter_eq(:target_type, opts[:target_type])
    |> Repo.all()
  end

  defp filter_prefix(query, _field, nil), do: query
  defp filter_prefix(query, _field, ""), do: query

  defp filter_prefix(query, field, value) do
    pattern = String.replace(value, ["\\", "%", "_"], fn c -> "\\" <> c end) <> "%"
    from e in query, where: like(field(e, ^field), ^pattern)
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, _field, ""), do: query
  defp filter_eq(query, field, value), do: from(e in query, where: field(e, ^field) == ^value)
end
