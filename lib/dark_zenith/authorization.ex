defmodule DarkZenith.Authorization do
  @moduledoc """
  The owner/collaborator/admin/public access matrix (DESIGN.md: Authorization).

  Identity-level checks only: API-key scope requirements and authentication
  method restrictions stay with the surface enforcing them.
  """

  import Ecto.Query, warn: false

  alias DarkZenith.Accounts.User
  alias DarkZenith.Collaborators.Collaborator
  alias DarkZenith.Repo
  alias DarkZenith.Repositories.Repository

  @doc """
  Whether the user (nil for anonymous) may read the repository: browse it,
  view packages, fetch repodata, and download RPMs. Public repositories are
  readable by everyone; private ones only by the owner, collaborators, and
  admins.
  """
  def can_read?(_user, %Repository{is_public: true}), do: true
  def can_read?(nil, %Repository{}), do: false

  def can_read?(%User{} = user, %Repository{} = repository) do
    user.is_admin or user.id == repository.user_id or collaborator?(user, repository)
  end

  @doc """
  Whether the user may modify the repository (update, delete, upload to, and
  manage collaborators). Owners and admins only — collaborators cannot.
  """
  def can_manage?(%User{} = user, %Repository{} = repository) do
    user.is_admin or user.id == repository.user_id
  end

  def can_manage?(nil, %Repository{}), do: false

  @doc "Whether the user holds a collaborator row on the repository."
  def collaborator?(%User{id: user_id}, %Repository{id: repository_id}) do
    Repo.exists?(
      from c in Collaborator,
        where: c.user_id == ^user_id and c.repository_id == ^repository_id
    )
  end
end
