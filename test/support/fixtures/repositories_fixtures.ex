defmodule DarkZenith.RepositoriesFixtures do
  @moduledoc """
  Test helpers for creating repositories via `DarkZenith.Repositories`.
  """

  alias DarkZenith.Repositories

  def unique_slug, do: "repo-#{System.unique_integer([:positive])}"

  def valid_repository_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      slug: unique_slug(),
      name: "Test Repository"
    })
  end

  def repository_fixture(owner, attrs \\ %{}) do
    {:ok, repository} = Repositories.create_repository(owner, valid_repository_attributes(attrs))
    repository
  end

  @doc """
  Gives a user a complete stored GPG key field set so fingerprint-matching
  rules can be exercised without the Phase 11 signing machinery.
  """
  def put_user_gpg_fingerprint(user, fingerprint \\ String.duplicate("A", 40)) do
    import Ecto.Query

    {1, _} =
      DarkZenith.Repo.update_all(
        from(u in DarkZenith.Accounts.User, where: u.id == ^user.id),
        set: [
          gpg_key_private: <<2, 0>>,
          gpg_key_public: "-----BEGIN PGP PUBLIC KEY BLOCK-----\ntest",
          gpg_key_fingerprint: fingerprint,
          gpg_signing_fingerprint: fingerprint,
          gpg_key_expires_at: nil
        ]
      )

    %{user | gpg_key_fingerprint: fingerprint, gpg_signing_fingerprint: fingerprint}
  end
end
