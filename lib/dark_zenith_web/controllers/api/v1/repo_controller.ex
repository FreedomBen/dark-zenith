defmodule DarkZenithWeb.Api.V1.RepoController do
  @moduledoc """
  `/api/v1/repos` (DESIGN.md: REST API — Repositories; API Contract Details).
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Repositories
  alias DarkZenithWeb.Api.{Pagination, RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.RepoJSON

  @create_fields ~w(name slug description is_public gpg_key_fingerprint sign_rpms)
  @update_fields ~w(name description is_public gpg_key_fingerprint sign_rpms existing_package_strategy)

  def index(conn, _params) do
    with {:ok, params} <- Strict.validate_query(conn, ["page", "per_page"]),
         {:ok, page, per_page} <- Pagination.parse(params) do
      user = private_read_user(conn.assigns.api_principal)

      {repositories, total} =
        user
        |> Repositories.visible_repositories_query()
        |> Pagination.paginate(page, per_page)

      json(
        conn,
        Pagination.envelope(Enum.map(repositories, &RepoJSON.data/1), page, per_page, total)
      )
    end
  end

  def create(conn, _params) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user} <- require_authenticated(conn),
         :ok <- require_api_key_scope(conn, "repo:create"),
         {:ok, body} <- Strict.validate_json_body(conn, @create_fields, ["name", "slug"]) do
      case Repositories.create_repository(user, body) do
        {:ok, repository} ->
          conn
          |> put_status(201)
          |> json(%{"data" => RepoJSON.data(repository)})

        {:error, :quota_exceeded} ->
          {:error, :conflict, "conflict_repository_quota_exceeded"}

        {:error, :signing_unavailable} ->
          {:error, :service_unavailable, "signing_unavailable", 30}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def show(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, repository} <- fetch_readable(conn, slug) do
      json(conn, %{"data" => RepoJSON.data(repository)})
    end
  end

  def update(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- fetch_manageable(conn, slug, "repo:update"),
         {:ok, body} <- Strict.validate_json_body(conn, @update_fields) do
      case Repositories.update_repository(user, repository, body) do
        {:ok, repository} ->
          json(conn, %{"data" => RepoJSON.data(repository)})

        {:error, :signing_transitions_not_implemented} ->
          {:error, :service_unavailable, "signing_unavailable", 30}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  def delete(conn, %{"slug" => slug}) do
    with {:ok, _} <- Strict.validate_query(conn),
         {:ok, user, repository} <- fetch_manageable(conn, slug, "repo:delete"),
         :ok <- Repositories.delete_repository(user, repository) do
      send_resp(conn, 204, "")
    else
      {:error, :forbidden} -> {:error, :forbidden}
      other -> other
    end
  end

  ## Principal helpers

  # Only credentials granting private read access surface private
  # repositories in listings: session tokens/cookies always, API keys only
  # with repo:read.
  defp private_read_user(principal) do
    case principal do
      {:authenticated, user, {:api_key, key}} ->
        if "repo:read" in key.scopes, do: user, else: nil

      {:authenticated, user, _} ->
        user

      _ ->
        nil
    end
  end

  defp require_authenticated(conn) do
    case conn.assigns.api_principal do
      {:authenticated, user, _kind} -> {:ok, user}
      _ -> {:error, :unauthenticated}
    end
  end

  defp require_api_key_scope(conn, scope) do
    case conn.assigns.api_principal do
      {:authenticated, _user, {:api_key, key}} ->
        if scope in key.scopes, do: :ok, else: {:error, :forbidden}

      _ ->
        :ok
    end
  end

  defdelegate fetch_readable(conn, slug), to: RepoAccess
  defdelegate fetch_manageable(conn, slug, scope), to: RepoAccess
end
