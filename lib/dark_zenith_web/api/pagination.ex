defmodule DarkZenithWeb.Api.Pagination do
  @moduledoc """
  The standard paginated list envelope (DESIGN.md: API Contract Details).

  `page` defaults to 1 and must be an integer from 1 through 10 000;
  `per_page` defaults to 50 and larger positive integers are clamped to 100.
  `total` and `total_pages` are decimal strings, while `page`/`per_page`
  remain JSON numbers.
  """

  import Ecto.Query

  alias DarkZenith.Repo

  @max_page 10_000
  @default_per_page 50
  @max_per_page 100

  @doc """
  Parses `page`/`per_page` from a validated query-param map. Returns
  `{:ok, page, per_page}` or `{:error, :validation_failed, details}`.
  """
  def parse(params) do
    with {:ok, page} <- parse_int(params, "page", 1),
         {:ok, per_page} <- parse_int(params, "per_page", @default_per_page) do
      cond do
        page < 1 or page > @max_page ->
          {:error, :validation_failed, %{"page" => ["must be between 1 and #{@max_page}"]}}

        per_page < 1 ->
          {:error, :validation_failed, %{"per_page" => ["must be a positive integer"]}}

        true ->
          {:ok, page, min(per_page, @max_per_page)}
      end
    end
  end

  @doc "Runs the query with limit/offset and returns `{entries, total}`."
  def paginate(query, page, per_page) do
    total = Repo.aggregate(exclude(query, :order_by), :count)

    entries =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {entries, total}
  end

  @doc "Builds the pagination envelope map."
  def envelope(data, page, per_page, total) do
    total_pages = if total == 0, do: 0, else: div(total + per_page - 1, per_page)

    %{
      "data" => data,
      "pagination" => %{
        "page" => page,
        "per_page" => per_page,
        "total" => Integer.to_string(total),
        "total_pages" => Integer.to_string(total_pages)
      }
    }
  end

  defp parse_int(params, key, default) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int}
          _ -> {:error, :validation_failed, %{key => ["must be an integer"]}}
        end
    end
  end
end
