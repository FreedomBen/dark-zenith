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

  @client_ip_key {__MODULE__, :client_ip}

  @doc """
  Stores the resolved client IP for this process so `record!/2` calls made
  by context functions default to it (set by `DarkZenithWeb.AuditContext`
  for HTTP requests and LiveView processes). Background/system processes
  never set it, so their events record a null `ip`.
  """
  def put_client_ip(ip) when is_binary(ip) or is_nil(ip) do
    Process.put(@client_ip_key, ip)
    :ok
  end

  @doc "The process-scoped client IP, or nil outside a client-request process."
  def client_ip, do: Process.get(@client_ip_key)

  @doc """
  Records one audit event. Options:

    * `:actor` — the acting `%User{}`, or nil for unauthenticated/system events
    * `:target` — `{type, id}` with type an atom/string from the allowed target
      types, or a bare type for string-keyed targets (`:slug` uses metadata)
    * `:ip` — client IP string as resolved by client IP detection; defaults
      to the process-scoped client IP (see `put_client_ip/1`), so pass an
      explicit nil to force a system event from a request process
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
      ip: Keyword.get_lazy(opts, :ip, &client_ip/0),
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
