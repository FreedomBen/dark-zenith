defmodule DarkZenith.Signing do
  @moduledoc """
  GPG signing operations (DESIGN.md: GPG Signing).

  Dispatches to the configured `:signing_impl` module; the default is the
  real gpg-backed implementation. `DarkZenith.Signing.Unavailable` remains
  available for outage simulation in tests.
  """

  @callback sign_repomd(owner :: struct(), repomd_xml :: binary()) ::
              {:ok, String.t()} | {:error, :unavailable} | {:error, :expired}

  @doc """
  Produces a detached ASCII-armored signature over the exact `repomd.xml`
  bytes with the owner's signing key. Returns `{:ok, armored_signature}`,
  `{:error, :unavailable}`, or `{:error, :expired}` for a key past its
  effective expiry (fail closed, non-retryable).
  """
  def sign_repomd(owner, repomd_xml) do
    impl().sign_repomd(owner, repomd_xml)
  end

  defp impl do
    Application.get_env(:dark_zenith, :signing_impl, DarkZenith.Signing.Gpg)
  end
end
