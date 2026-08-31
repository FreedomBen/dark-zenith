defmodule DarkZenith.Jobs.GpgKeyReencryptionTest do
  # Not async: overrides the secret-key-base configuration.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures

  alias DarkZenith.Accounts.User
  alias DarkZenith.Crypto.GpgKeyEnvelope
  alias DarkZenith.Jobs.{GpgKeyReencryption, GpgKeyReencryptionRow}

  @plaintext "-----BEGIN PGP PRIVATE KEY BLOCK-----\nTEST\n-----END PGP PRIVATE KEY BLOCK-----\n"

  setup do
    current = Application.fetch_env!(:dark_zenith, :secret_key_base)
    previous = String.duplicate("previous-secret-key-base-0123456789", 2)
    Application.put_env(:dark_zenith, :previous_secret_key_base, previous)
    on_exit(fn -> Application.delete_env(:dark_zenith, :previous_secret_key_base) end)

    %{user: user_fixture(), current: current, previous: previous}
  end

  defp put_envelope!(user, envelope) do
    fingerprint = String.duplicate("D", 40)

    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [
          gpg_key_private: envelope,
          gpg_key_public: "pub",
          gpg_key_fingerprint: fingerprint,
          gpg_signing_fingerprint: fingerprint
        ]
      )

    envelope
  end

  test "the scan enqueues one row job per stored envelope", ctx do
    put_envelope!(ctx.user, GpgKeyEnvelope.encrypt(@plaintext, ctx.user.id))

    assert :ok = perform_job(GpgKeyReencryption, %{})
    assert_enqueued(worker: GpgKeyReencryptionRow, args: %{user_id: ctx.user.id})
  end

  test "an envelope under the previous base is rewritten to the current one", ctx do
    old =
      put_envelope!(
        ctx.user,
        GpgKeyEnvelope.encrypt_with_secret(@plaintext, ctx.user.id, ctx.previous)
      )

    assert :ok = perform_job(GpgKeyReencryptionRow, %{"user_id" => ctx.user.id})

    rewritten = Repo.get!(User, ctx.user.id).gpg_key_private
    refute rewritten == old

    assert {:ok, @plaintext} =
             GpgKeyEnvelope.decrypt_with_secret(rewritten, ctx.user.id, ctx.current)
  end

  test "a current-base v2 envelope is a no-op", ctx do
    envelope = put_envelope!(ctx.user, GpgKeyEnvelope.encrypt(@plaintext, ctx.user.id))

    assert :ok = perform_job(GpgKeyReencryptionRow, %{"user_id" => ctx.user.id})
    assert Repo.get!(User, ctx.user.id).gpg_key_private == envelope
  end

  test "an undecryptable envelope cancels for admin intervention", ctx do
    put_envelope!(ctx.user, <<2, 0, 1, 2, 3>>)

    assert {:cancel, :undecryptable_envelope} =
             perform_job(GpgKeyReencryptionRow, %{"user_id" => ctx.user.id})
  end

  test "a concurrently removed key is a successful no-op", _ctx do
    assert :ok = perform_job(GpgKeyReencryptionRow, %{"user_id" => Ecto.UUID.generate()})
  end
end
