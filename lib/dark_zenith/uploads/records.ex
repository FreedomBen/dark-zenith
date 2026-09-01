defmodule DarkZenith.Uploads.Records do
  @moduledoc """
  Package upload records (DESIGN.md: Package Upload Records): written beside
  each upload intent as `in_flight`, finalized exactly once by a
  compare-and-swap in the same transaction that makes the intent terminal,
  and never deleted by application code.

  Listing queries left-join the live intent so an `in_flight` row can report
  real-time progress; the repository listing, the admin instance-wide view,
  and the REST endpoint all read through here.
  """

  import Ecto.Query

  alias DarkZenith.Repo
  alias DarkZenith.Repositories.Repository
  alias DarkZenith.Uploads.{Intent, Record}

  ## Writes

  @doc """
  Writes the `in_flight` record for a freshly inserted intent, snapshotting
  the repository slug and the initiator's email. Call inside the intent's
  creation transaction.
  """
  def create_for_intent!(%Intent{} = intent, repository_slug, user_email) do
    Repo.insert!(%Record{
      repository_id: intent.repository_id,
      repository_slug: repository_slug,
      user_id: intent.user_id,
      user_email: user_email,
      intent_id: intent.id,
      package_id: intent.package_id,
      mode: intent.mode,
      original_filename: intent.original_filename,
      declared_size: intent.declared_size,
      outcome: "in_flight",
      started_at: intent.inserted_at
    })
  end

  @doc """
  Finalizes the intent's record: a compare-and-swap on `outcome =
  "in_flight"`, so a replayed or racing writer cannot rewrite a recorded
  outcome. Fields: `:final_size`/`:nevra` (success), `:error_code`/
  `:error_detail` (failure), `:finished_at` (defaults to now). Returns `:ok`
  when this call finalized the record and `:noop` when nothing matched.
  """
  def finalize!(intent_id, outcome, fields \\ []) do
    unless outcome in Record.terminal_outcomes() do
      raise ArgumentError, "not a terminal outcome: #{inspect(outcome)}"
    end

    now = DateTime.utc_now(:second)

    set =
      [outcome: outcome, finished_at: Keyword.get(fields, :finished_at, now), updated_at: now] ++
        Keyword.take(fields, outcome_fields(outcome))

    {count, _} =
      Repo.update_all(
        from(r in Record, where: r.intent_id == ^intent_id and r.outcome == "in_flight"),
        set: set
      )

    if count == 1, do: :ok, else: :noop
  end

  defp outcome_fields("succeeded"), do: [:final_size, :nevra]
  defp outcome_fields("failed"), do: [:error_code, :error_detail]
  defp outcome_fields(_outcome), do: []

  @doc """
  Finalizes every still `in_flight` record among the given intents as
  `canceled` — the repository-deletion and user-deletion rule, applied in
  those transactions before the intent rows go. Returns the count.
  """
  def cancel_in_flight!([]), do: 0

  def cancel_in_flight!(intent_ids) when is_list(intent_ids) do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(r in Record, where: r.intent_id in ^intent_ids and r.outcome == "in_flight"),
        set: [outcome: "canceled", finished_at: now, updated_at: now]
      )

    count
  end

  @doc """
  The hourly safety net: an anti-join from `in_flight` records against
  upload intents finalizes any record whose intent row no longer exists as
  `canceled`, writing the sweep's own time to `finished_at`. Repairs state
  rather than performing an action, so it records no audit event.
  """
  def reconcile_orphans do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(r in Record,
          as: :record,
          where:
            r.outcome == "in_flight" and
              not exists(from(i in Intent, where: i.id == parent_as(:record).intent_id))
        ),
        set: [outcome: "canceled", finished_at: now, updated_at: now]
      )

    count
  end

  ## Reads

  @doc "The record for an intent id, or nil."
  def get_by_intent(intent_id), do: Repo.get_by(Record, intent_id: intent_id)

  @doc """
  The repository-scoped listing: rows ordered by `started_at` descending then
  `id` ascending, optionally restricted to an outcome subset. Options:
  `:outcomes`, `:page`, `:per_page`. Returns `{records, total}`.
  """
  def list_repository_records(repository_id, opts \\ []) do
    repository_id
    |> repository_query(opts[:outcomes])
    |> paginate(opts)
  end

  @doc "The unpaginated repository listing query."
  def repository_query(repository_id, outcomes \\ nil) do
    base_query()
    |> where([r], r.repository_id == ^repository_id)
    |> filter_outcomes(outcomes)
  end

  @doc """
  The admin instance-wide listing (DESIGN.md: Admin — Upload records).
  Options: `:repository` (exact slug snapshot), `:initiator` (exact email
  snapshot), `:outcomes`, `:page`, `:per_page`. Returns `{records, total}`.
  """
  def list_admin_records(opts \\ []) do
    base_query()
    |> filter_eq(:repository_slug, opts[:repository])
    |> filter_eq(:user_email, opts[:initiator])
    |> filter_outcomes(opts[:outcomes])
    |> paginate(opts)
  end

  @doc "The repository's `in_flight` count, served by the partial index."
  def in_flight_count(repository_id) do
    Repo.aggregate(
      from(r in Record, where: r.repository_id == ^repository_id and r.outcome == "in_flight"),
      :count
    )
  end

  @doc """
  Maps each given repository id that still names a live repository to its
  current slug, so a view can link a record only while its `repository_id`
  is live (a revived slug is a different repository with a different UUID).
  """
  def live_repositories([]), do: %{}

  def live_repositories(repository_ids) when is_list(repository_ids) do
    Repo.all(
      from r in Repository,
        where: r.id in ^Enum.uniq(repository_ids),
        select: {r.id, r.slug}
    )
    |> Map.new()
  end

  @doc """
  Parses the `outcome` filter shared by the REST listing and both web
  surfaces: a comma-separated subset of the outcomes, each entry matched
  exactly (no trimming, no case folding). An unknown outcome, a blank entry,
  or a repeated entry is rejected. `nil` means no filter.
  """
  def parse_outcome_filter(nil), do: {:ok, nil}

  def parse_outcome_filter(value) when is_binary(value) do
    entries = String.split(value, ",")

    cond do
      Enum.any?(entries, &(&1 not in Record.outcomes())) ->
        {:error, "must be a comma-separated subset of #{Enum.join(Record.outcomes(), ", ")}"}

      entries != Enum.uniq(entries) ->
        {:error, "must not repeat an outcome"}

      true ->
        {:ok, entries}
    end
  end

  def parse_outcome_filter(_value), do: {:error, "must be a string"}

  ## Query helpers

  # `live_status` is the backing intent's status only while the record is
  # in_flight; a terminal record reads null even inside its intent's 24-hour
  # retention window, and so does an in_flight record whose intent is gone.
  defp base_query do
    from r in Record,
      left_join: i in Intent,
      on: i.id == r.intent_id,
      order_by: [desc: r.started_at, asc: r.id],
      select_merge: %{
        live_status: fragment("CASE WHEN ? = 'in_flight' THEN ? END", r.outcome, i.status)
      }
  end

  defp filter_outcomes(query, nil), do: query
  defp filter_outcomes(query, outcomes), do: where(query, [r], r.outcome in ^outcomes)

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, _field, ""), do: query
  defp filter_eq(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp paginate(query, opts) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    total = Repo.aggregate(exclude(query, :order_by), :count)

    entries =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {entries, total}
  end
end
