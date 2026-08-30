defmodule DarkZenith.Accounts.ApiKey do
  @moduledoc """
  Long-lived scoped API keys (`dzak_` prefix) — DESIGN.md: API Keys.

  Only `HMAC-SHA-256(SECRET_KEY_BASE, full_key_string)` is stored, as lowercase
  hex, plus the first 12 characters for display. Scopes are stored in canonical
  form: deduplicated and sorted lexicographically. Expired keys remain listed
  until explicitly deleted but are rejected as credentials.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(repo:read repo:create repo:update repo:delete package:upload package:delete)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime
    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The list of valid scope strings."
  def valid_scopes, do: @valid_scopes

  @doc """
  Changeset for creating an API key. `key_hash`/`key_prefix` are set separately
  at build time; this validates the user-supplied fields.
  """
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :scopes])
    |> validate_length(:name, max: 100)
    |> validate_no_control_characters(:name)
    |> canonicalize_scopes()
    |> validate_future_expiration()
  end

  @doc "Whether the key is expired at the current time."
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp validate_no_control_characters(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if String.match?(value, ~r/[\x00-\x1F\x7F]/) do
        [{field, "cannot contain control characters"}]
      else
        []
      end
    end)
  end

  # Scope input must be an array of strings; unknown or empty values are
  # rejected, duplicates are collapsed, and the result is stored in
  # lexicographic order (the canonical representation).
  defp canonicalize_scopes(changeset) do
    changeset
    |> validate_subset(:scopes, @valid_scopes, message: "contains an invalid scope")
    |> validate_length(:scopes, min: 1)
    |> update_change(:scopes, fn scopes -> scopes |> Enum.uniq() |> Enum.sort() end)
  end

  defp validate_future_expiration(changeset) do
    validate_change(changeset, :expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
        []
      else
        [expires_at: "must be in the future"]
      end
    end)
  end
end
