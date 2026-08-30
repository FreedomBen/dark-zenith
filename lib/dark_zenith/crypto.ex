defmodule DarkZenith.Crypto do
  @moduledoc """
  Root key material handling and token hashing.

  `SECRET_KEY_BASE` is the root key material for API-key/session-token hashing
  and for the GPG private-key encryption envelope. It is treated as a raw UTF-8
  byte sequence: never trimmed, Unicode-normalized, or base64-decoded.
  """

  @min_secret_bytes 64

  @doc """
  HMAC-SHA-256 of the full token string (including its `dzak_`/`dzst_` prefix),
  keyed by the secret key base and encoded as lowercase hex.
  """
  def token_hash(secret_key_base, full_token_string)
      when is_binary(secret_key_base) and is_binary(full_token_string) do
    :crypto.mac(:hmac, :sha256, secret_key_base, full_token_string)
    |> Base.encode16(case: :lower)
  end

  @doc "Same as `token_hash/2` using the configured `secret_key_base`."
  def token_hash(full_token_string) when is_binary(full_token_string) do
    token_hash(secret_key_base(), full_token_string)
  end

  @doc "The configured secret key base for this node."
  def secret_key_base do
    Application.fetch_env!(:dark_zenith, :secret_key_base)
  end

  @doc "The configured previous secret key base during a rotation window, or nil."
  def previous_secret_key_base do
    Application.get_env(:dark_zenith, :previous_secret_key_base)
  end

  @doc """
  Validates production secret key base requirements: at least #{@min_secret_bytes}
  raw UTF-8 bytes.
  """
  def validate_secret_key_base(value) when is_binary(value) do
    if byte_size(value) >= @min_secret_bytes do
      :ok
    else
      {:error, "must contain at least #{@min_secret_bytes} raw bytes"}
    end
  end

  def validate_secret_key_base(_value), do: {:error, "must be a string"}

  @doc """
  Validates the current and (optional) previous secret key bases together: both
  meet the minimum length, and the previous value must differ from the current.
  """
  def validate_secret_key_bases(current, previous) do
    with :ok <- validate_secret_key_base(current) do
      cond do
        is_nil(previous) ->
          :ok

        previous == current ->
          {:error, "PREVIOUS_SECRET_KEY_BASE must differ from SECRET_KEY_BASE"}

        true ->
          validate_secret_key_base(previous)
      end
    end
  end
end
