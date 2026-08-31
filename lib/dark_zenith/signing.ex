defmodule DarkZenith.Signing do
  @moduledoc """
  GPG signing operations (DESIGN.md: GPG Signing).

  Dispatches to the configured `:signing_impl` module; the default is the
  real gpg-backed implementation. `DarkZenith.Signing.Unavailable` remains
  available for outage simulation in tests.
  """

  @callback sign_repomd(owner :: struct(), repomd_xml :: binary()) ::
              {:ok, String.t()} | {:error, :unavailable} | {:error, :expired}

  @callback sign_rpm(
              owner :: struct(),
              source_path :: Path.t(),
              workdir :: Path.t(),
              metadata :: DarkZenith.Rpm.Metadata.t()
            ) ::
              {:ok, Path.t()}
              | {:error, :unavailable}
              | {:error, :expired}
              | {:error, :validation_failed}
              | {:error, :rpm_verification_unavailable}

  @doc """
  Produces a detached ASCII-armored signature over the exact `repomd.xml`
  bytes with the owner's signing key. Returns `{:ok, armored_signature}`,
  `{:error, :unavailable}`, or `{:error, :expired}` for a key past its
  effective expiry (fail closed, non-retryable).
  """
  def sign_repomd(owner, repomd_xml) do
    impl().sign_repomd(owner, repomd_xml)
  end

  @doc """
  Signs one RPM file with the owner's exact signing key, preserving the
  package's v4/v6 format (`--rpmv4` compatibility signature for v6) and
  choosing `--addsign` for unsigned input or `--resign` when the parsed
  source already carries an OpenPGP package signature, then verifies the
  output against the owner's public key. Returns the signed file path
  inside `workdir`.
  """
  def sign_rpm(owner, source_path, workdir, metadata) do
    impl().sign_rpm(owner, source_path, workdir, metadata)
  end

  defp impl do
    Application.get_env(:dark_zenith, :signing_impl, DarkZenith.Signing.Gpg)
  end
end
