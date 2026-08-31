defmodule DarkZenithWeb.Api.V1.PackageController do
  @moduledoc """
  `/api/v1/repos/:slug/packages` (DESIGN.md: REST API — Packages; API
  Contract Details): filtered/sorted listing, detail, the ten bounded
  subresources, and deletion.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Packages
  alias DarkZenithWeb.Api.{Pagination, RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.PackageJSON

  @subresources ~w(requires provides conflicts obsoletes recommends suggests supplements enhances files changelogs)
  @filter_max 256

  def index(conn, %{"slug" => slug}) do
    with {:ok, params} <-
           Strict.validate_query(conn, ["page", "per_page", "q", "name", "arch", "sort"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, filters} <- parse_filters(params),
         {:ok, repository} <- RepoAccess.fetch_readable(conn, slug) do
      {packages, total} =
        repository.id
        |> Packages.list_query(filters)
        |> Pagination.paginate(page, per_page)

      data = Enum.map(packages, &PackageJSON.list(&1, repository))
      json(conn, Pagination.envelope(data, page, per_page, total))
    end
  end

  def show(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, repository, package} <- fetch_package(conn, slug, id) do
      json(conn, %{"data" => PackageJSON.detail(package, repository)})
    end
  end

  def subresource(conn, %{"slug" => slug, "id" => id, "collection" => collection}) do
    with :ok <- validate_collection(collection),
         {:ok, params} <- Strict.validate_query(conn, ["page", "per_page"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, _repository, package} <- fetch_package(conn, slug, id) do
      entries = sorted_entries(package, collection)

      data =
        entries
        |> Enum.drop((page - 1) * per_page)
        |> Enum.take(per_page)

      json(conn, Pagination.envelope(data, page, per_page, length(entries)))
    end
  end

  def delete(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "package:delete"),
         package when not is_nil(package) <- Packages.get_package(repository, id),
         :ok <- Packages.delete_package(user, repository, package) do
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  ## Helpers

  defp fetch_package(conn, slug, id) do
    with {:ok, repository} <- RepoAccess.fetch_readable(conn, slug) do
      case Packages.get_package(repository, id) do
        nil -> {:error, :not_found}
        package -> {:ok, repository, package}
      end
    end
  end

  defp validate_collection(collection) do
    if collection in @subresources, do: :ok, else: {:error, :not_found}
  end

  # Dependency arrays retain stored order; files sort by path (UTF-8 byte
  # order) then ordinal; changelogs by timestamp descending, ties in
  # original order (Enum.sort_by is stable).
  defp sorted_entries(package, "files") do
    package.files |> Enum.sort_by(& &1["path"])
  end

  defp sorted_entries(package, "changelogs") do
    package.changelogs |> Enum.sort_by(& &1["timestamp"], :desc)
  end

  defp sorted_entries(package, collection) do
    Map.fetch!(package, String.to_existing_atom(collection))
  end

  defp parse_filters(params) do
    with {:ok, q} <- parse_filter(params, "q", blank: :absent),
         {:ok, name} <- parse_filter(params, "name", blank: :reject),
         {:ok, arch} <- parse_filter(params, "arch", blank: :reject),
         {:ok, sort} <- parse_sort(params["sort"]) do
      {:ok, [q: q, name: name, arch: arch, sort: sort]}
    end
  end

  defp parse_filter(params, key, blank: blank_rule) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, nil}

      {:ok, raw} ->
        value = String.trim(raw)

        cond do
          String.length(value) > @filter_max ->
            {:error, :validation_failed, %{key => ["is too long"]}}

          value == "" and blank_rule == :absent ->
            {:ok, nil}

          value == "" ->
            {:error, :validation_failed, %{key => ["must not be blank"]}}

          true ->
            {:ok, value}
        end
    end
  end

  defp parse_sort(nil), do: {:ok, nil}

  defp parse_sort(raw) do
    {direction, field} =
      case raw do
        "-" <> rest -> {:desc, rest}
        rest -> {:asc, rest}
      end

    if field in ~w(name version arch inserted_at) do
      {:ok, {String.to_existing_atom(field), direction}}
    else
      {:error, :validation_failed, %{"sort" => ["is not a valid sort"]}}
    end
  end
end
