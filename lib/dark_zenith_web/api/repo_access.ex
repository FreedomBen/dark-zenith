defmodule DarkZenithWeb.Api.RepoAccess do
  @moduledoc """
  Shared repository lookup + authorization for `/api/v1/repos/:slug/...`
  endpoints (DESIGN.md: API Contract Details — 404 masking and the 401/403
  discipline).
  """

  alias DarkZenith.Authorization
  alias DarkZenith.Repositories

  @doc """
  Read access with the 404 masking rule: public repositories are readable by
  every principal; private ones by owner/collaborator/admin, with API keys
  additionally requiring `repo:read`.
  """
  def fetch_readable(conn, slug) do
    repository = Repositories.get_repository_by_slug(slug)
    principal = conn.assigns.api_principal

    cond do
      repository && repository.is_public ->
        {:ok, repository}

      repository && readable_private?(principal, repository) ->
        {:ok, repository}

      true ->
        {:error, :not_found}
    end
  end

  @doc """
  The user whose private repositories a listing or search may include:
  session tokens and cookies always; API keys only with `repo:read`; nil for
  everything else (DESIGN.md: API Contract Details — `GET /api/v1/repos` and
  `GET /api/v1/search/packages` visibility).
  """
  def private_read_user(principal) do
    case principal do
      {:authenticated, user, {:api_key, key}} ->
        if "repo:read" in key.scopes, do: user, else: nil

      {:authenticated, user, _} ->
        user

      _ ->
        nil
    end
  end

  @doc "Whether the principal can read the private repository."
  def readable_private?({:authenticated, user, kind}, repository) do
    scope_ok? =
      case kind do
        {:api_key, key} -> "repo:read" in key.scopes
        _ -> true
      end

    scope_ok? and Authorization.can_read?(user, repository)
  end

  def readable_private?(_principal, _repository), do: false

  @doc """
  Management access: owners and admins act with the matching API-key scope;
  everyone else gets 403 when they can see the repository and 404 when they
  cannot. Anonymous requests get 401 on public repositories and the masked
  404 on private/unknown slugs.
  """
  def fetch_manageable(conn, slug, scope) do
    repository = Repositories.get_repository_by_slug(slug)
    principal = conn.assigns.api_principal

    case principal do
      {:authenticated, user, kind} ->
        cond do
          is_nil(repository) ->
            {:error, :not_found}

          Authorization.can_manage?(user, repository) ->
            case kind do
              {:api_key, key} ->
                if scope in key.scopes, do: {:ok, user, repository}, else: {:error, :forbidden}

              _ ->
                {:ok, user, repository}
            end

          repository.is_public or readable_private?(principal, repository) ->
            {:error, :forbidden}

          true ->
            {:error, :not_found}
        end

      :anonymous ->
        if repository && repository.is_public,
          do: {:error, :unauthenticated},
          else: {:error, :not_found}

      _invalid ->
        {:error, :not_found}
    end
  end
end
