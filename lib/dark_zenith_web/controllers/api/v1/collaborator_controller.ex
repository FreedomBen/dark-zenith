defmodule DarkZenithWeb.Api.V1.CollaboratorController do
  @moduledoc """
  `/api/v1/repos/:slug/collaborators` (DESIGN.md: REST API — Collaborators;
  API Contract Details). Owner/admin only: listing needs `repo:read` on API
  keys, mutations `repo:update`.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Collaborators
  alias DarkZenithWeb.Api.{Pagination, RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.CollaboratorJSON

  def index(conn, %{"slug" => slug}) do
    with {:ok, params} <- Strict.validate_query(conn, ["page", "per_page"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, _user, repository} <- RepoAccess.fetch_manageable(conn, slug, "repo:read") do
      rows = Collaborators.list_rows(repository)

      data =
        rows
        |> Enum.drop((page - 1) * per_page)
        |> Enum.take(per_page)
        |> Enum.map(&CollaboratorJSON.row/1)

      json(conn, Pagination.envelope(data, page, per_page, length(rows)))
    end
  end

  def create(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "repo:update"),
         {:ok, body} <- Strict.validate_json_body(conn, ["email"], ["email"]) do
      case Collaborators.add_collaborator(user, repository, body["email"]) do
        {:ok, :created, row} ->
          conn
          |> put_status(201)
          |> json(%{"data" => CollaboratorJSON.row(row)})

        {:ok, :existing, row} ->
          json(conn, %{"data" => CollaboratorJSON.row(row)})

        {:error, :public_repository} ->
          {:error, :validation_failed,
           %{"repository" => ["collaborators can only be added to private repositories"]}}

        {:error, :quota_exceeded} ->
          {:error, :conflict, "conflict_collaborator_quota_exceeded"}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  def delete(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "repo:update"),
         :ok <- Collaborators.remove_collaborator(user, repository, id) do
      send_resp(conn, 204, "")
    end
  end

  def delete_invitation(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- RepoAccess.fetch_manageable(conn, slug, "repo:update"),
         :ok <- Collaborators.cancel_invitation(user, repository, id) do
      send_resp(conn, 204, "")
    end
  end
end
