defmodule DarkZenith.Accounts.SessionToken do
  @moduledoc """
  Short-lived API bearer tokens (`dzst_` prefix) issued by the login endpoint
  for interactive/CLI use (DESIGN.md: Session Tokens).

  Only `HMAC-SHA-256(SECRET_KEY_BASE, full_token_string)` is stored, as
  lowercase hex; the plaintext is shown exactly once at creation. Session
  tokens carry no scopes: they authorize API requests as the logged-in user.
  """

  use Ecto.Schema

  @validity_in_hours 24

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "session_tokens" do
    field :token_hash, :string
    field :expires_at, :utc_datetime
    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The token validity period in hours."
  def validity_in_hours, do: @validity_in_hours

  @doc """
  Builds a new session token for the user. Returns `{plaintext, struct}`;
  the plaintext is never stored.
  """
  def build(user) do
    {plaintext, token_hash} = DarkZenith.Crypto.generate_token("dzst_")

    {plaintext,
     %__MODULE__{
       token_hash: token_hash,
       user_id: user.id,
       expires_at: DateTime.add(DateTime.utc_now(:second), @validity_in_hours, :hour)
     }}
  end
end
