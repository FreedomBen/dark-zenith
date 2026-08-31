defmodule DarkZenith.Accounts.EmailLock do
  @moduledoc """
  Transaction-scoped PostgreSQL advisory lock derived from a normalized email
  address (DESIGN.md: User Lifecycle).

  Every transaction that can create a user at an email, confirm an email
  change, or create/refresh/convert a collaborator invitation acquires this
  lock first and then repeats its user and invitation lookups while holding
  it, making the user-versus-invitation decision atomic across registration,
  admin provisioning, email confirmation, and collaborator addition. Hash
  collisions merely serialize unrelated addresses; database uniqueness
  constraints remain the final defense.
  """

  alias DarkZenith.Repo

  @doc """
  Acquires the advisory lock for the normalized email. Must be called inside
  a transaction; the lock releases when that transaction ends.
  """
  def acquire!(normalized_email) when is_binary(normalized_email) do
    <<key::signed-integer-64, _rest::binary>> =
      :crypto.hash(:sha256, "dark_zenith:email:" <> normalized_email)

    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end
end
