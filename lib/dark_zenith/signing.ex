defmodule DarkZenith.Signing do
  @moduledoc """
  GPG signing operations (DESIGN.md: GPG Signing).

  Dispatches to the configured `:signing_impl` module. The real gpg/rpmsign
  integration arrives with the signing phase; the default implementation
  reports the infrastructure as unavailable, which maps to the spec's
  `503 signing_unavailable` behavior.
  """

  @callback sign_repomd(owner :: struct(), repomd_xml :: binary()) ::
              {:ok, String.t()} | {:error, :unavailable}

  @doc """
  Produces a detached ASCII-armored signature over the exact `repomd.xml`
  bytes with the owner's signing key. Returns `{:ok, armored_signature}` or
  `{:error, :unavailable}`.
  """
  def sign_repomd(owner, repomd_xml) do
    impl().sign_repomd(owner, repomd_xml)
  end

  defp impl do
    Application.get_env(:dark_zenith, :signing_impl, DarkZenith.Signing.Unavailable)
  end
end
