defmodule DarkZenithWeb.Api.V1.ApiKeyJSON do
  @moduledoc """
  API key resource shape (DESIGN.md: API Contract Details). The plaintext
  `key` appears only in the creation response; `key_hash` never appears.
  """

  alias DarkZenith.Accounts.ApiKey

  def data(api_key, plaintext \\ nil) do
    base = %{
      "id" => api_key.id,
      "name" => api_key.name,
      "key_prefix" => api_key.key_prefix,
      "scopes" => api_key.scopes,
      "expires_at" => api_key.expires_at && DateTime.to_iso8601(api_key.expires_at),
      "is_expired" => ApiKey.expired?(api_key),
      "inserted_at" => DateTime.to_iso8601(api_key.inserted_at),
      "updated_at" => DateTime.to_iso8601(api_key.updated_at)
    }

    if plaintext, do: Map.put(base, "key", plaintext), else: base
  end
end
