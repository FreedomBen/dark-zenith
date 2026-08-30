defmodule DarkZenith.Crypto.GpgKeyEnvelope do
  @moduledoc """
  Versioned binary encryption envelope for GPG private keys at rest.

  Layout (all versions): 1-byte version, 16-byte salt, 12-byte nonce, 16-byte
  AEAD tag, ciphertext. The AEAD key is derived from the secret key base with
  HKDF-SHA-256 using the per-version context string, and the AAD binds the
  ciphertext to the owning user's UUID. New writes always use the current
  version (`v2`); reads dispatch by the stored version byte.

  See DESIGN.md, "GPG private key encryption", including the fixed test vectors
  this module must reproduce.
  """

  alias DarkZenith.Crypto

  @current_version 2
  @supported_versions [1, 2]
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16

  @doc """
  Derives the 32-byte AES-256-GCM key for an envelope version from the secret
  key base and salt, per HKDF-SHA-256 with the version's context string.
  """
  def derive_key(version, secret_key_base, salt)
      when version in @supported_versions and is_binary(secret_key_base) and
             byte_size(salt) == @salt_bytes do
    prk = :crypto.mac(:hmac, :sha256, salt, secret_key_base)
    :crypto.mac(:hmac, :sha256, prk, <<context(version)::binary, 1>>)
  end

  @doc """
  Encrypts an ASCII-armored private key for a user with the configured secret
  key base, producing a current-version envelope with fresh randomness.
  """
  def encrypt(plaintext, user_id) do
    encrypt_with_secret(plaintext, user_id, Crypto.secret_key_base())
  end

  @doc """
  Encrypts with an explicit secret. Options:

    * `:version` — envelope version (default #{@current_version})
    * `:salt` / `:nonce` — fixed values for test vectors only; fresh
      cryptographically random values are generated when absent
  """
  def encrypt_with_secret(plaintext, user_id, secret_key_base, opts \\ [])
      when is_binary(plaintext) and is_binary(user_id) and is_binary(secret_key_base) do
    version = Keyword.get(opts, :version, @current_version)
    true = version in @supported_versions
    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(@salt_bytes) end)
    nonce = Keyword.get_lazy(opts, :nonce, fn -> :crypto.strong_rand_bytes(@nonce_bytes) end)

    key = derive_key(version, secret_key_base, salt)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        aad(version, user_id),
        @tag_bytes,
        true
      )

    <<version, salt::binary, nonce::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts an envelope for a user. Attempts the configured secret key base and,
  on AEAD authentication failure only, retries with the configured previous
  secret key base when one is set. Options `:secret` and `:previous_secret`
  override the configured values.
  """
  def decrypt(envelope, user_id, opts \\ []) do
    secret = Keyword.get_lazy(opts, :secret, &Crypto.secret_key_base/0)

    previous =
      Keyword.get_lazy(opts, :previous_secret, &Crypto.previous_secret_key_base/0)

    case decrypt_with_secret(envelope, user_id, secret) do
      {:error, :decryption_failed} when is_binary(previous) ->
        decrypt_with_secret(envelope, user_id, previous)

      result ->
        result
    end
  end

  @doc """
  Decrypts an envelope with an explicit secret. Returns `{:ok, plaintext}`,
  `{:error, :decryption_failed}` on AEAD authentication failure,
  `{:error, :unsupported_version}` for an unknown version byte, or
  `{:error, :invalid_envelope}` for a structurally invalid value.
  """
  def decrypt_with_secret(envelope, user_id, secret_key_base)

  def decrypt_with_secret(
        <<version, salt::binary-size(@salt_bytes), nonce::binary-size(@nonce_bytes),
          tag::binary-size(@tag_bytes), ciphertext::binary>>,
        user_id,
        secret_key_base
      )
      when version in @supported_versions and is_binary(user_id) and is_binary(secret_key_base) do
    key = derive_key(version, secret_key_base, salt)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           aad(version, user_id),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end

  def decrypt_with_secret(<<version, _rest::binary>> = envelope, _user_id, _secret)
      when version not in @supported_versions and
             byte_size(envelope) >= 1 + @salt_bytes + @nonce_bytes + @tag_bytes do
    {:error, :unsupported_version}
  end

  def decrypt_with_secret(envelope, _user_id, _secret) when is_binary(envelope) do
    {:error, :invalid_envelope}
  end

  defp context(version), do: "dark_zenith:gpg_private_key:v#{version}"

  # The AAD binds the envelope to its owning user; user_id is the canonical
  # lowercase hyphenated ASCII UUID.
  defp aad(version, user_id), do: "#{context(version)}:#{String.downcase(user_id)}"
end
