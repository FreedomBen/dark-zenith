defmodule DarkZenith.Signing.Gpg do
  @moduledoc """
  The real metadata-signing implementation (DESIGN.md: Repository metadata
  signing): decrypts the owner's private key from its envelope — falling
  back to `PREVIOUS_SECRET_KEY_BASE` during rotation — and produces a
  detached armored signature over the exact `repomd.xml` bytes inside an
  ephemeral `GNUPGHOME`, forcing the exact signing fingerprint.

  An expired key fails closed with `{:error, :expired}` (the spec's
  non-retryable `conflict_gpg_key_expired`); a missing, undecryptable, or
  otherwise unusable key reports `{:error, :unavailable}`.
  """

  @behaviour DarkZenith.Signing

  alias DarkZenith.Crypto.GpgKeyEnvelope
  alias DarkZenith.Gpg

  @impl true
  def sign_repomd(owner, repomd_xml) do
    cond do
      is_nil(owner.gpg_key_private) or is_nil(owner.gpg_signing_fingerprint) ->
        {:error, :unavailable}

      expired?(owner) ->
        {:error, :expired}

      true ->
        with {:ok, private_armored} <- GpgKeyEnvelope.decrypt(owner.gpg_key_private, owner.id),
             {:ok, signature} <-
               Gpg.sign_detached(private_armored, owner.gpg_signing_fingerprint, repomd_xml) do
          {:ok, signature}
        else
          _other -> {:error, :unavailable}
        end
    end
  end

  defp expired?(%{gpg_key_expires_at: nil}), do: false

  defp expired?(%{gpg_key_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
