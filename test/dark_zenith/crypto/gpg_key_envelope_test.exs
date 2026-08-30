defmodule DarkZenith.Crypto.GpgKeyEnvelopeTest do
  use ExUnit.Case, async: true

  alias DarkZenith.Crypto.GpgKeyEnvelope

  # Fixed vectors from DESIGN.md (GPG private key encryption). The short IKM is
  # explicitly test-only data, exempt from the 64-byte production rule.
  @ikm "test-secret-key-base"
  @user_id "00000000-0000-4000-8000-000000000001"
  @salt Base.decode16!("000102030405060708090a0b0c0d0e0f", case: :lower)
  @nonce Base.decode16!("101112131415161718191a1b", case: :lower)
  @plaintext "-----BEGIN PGP PRIVATE KEY BLOCK-----\nTEST\n-----END PGP PRIVATE KEY BLOCK-----\n"

  @v1_key Base.decode16!("4ffe0b263e053b2e989b429a47caac0d4cc8fb4bb67f13d0854a59788c76cc33",
            case: :lower
          )
  @v2_key Base.decode16!("54520f77e307c3e71067ef43e4840bc2dc6e358a4e5ac57552ee08200401c86d",
            case: :lower
          )

  @v1_envelope Base.decode16!(
                 "01000102030405060708090a0b0c0d0e0f101112131415161718191a1b" <>
                   "dbf2d8de9d3a7bd94a6e856bcca54c2d395463ec41331ffe72bf035be495" <>
                   "fa9449584fdb7fd6ccd274d4ae29bf7c2eddaaf87a9b37c19f5b6099fa67" <>
                   "f1a19ca42ade38a077d421ed4969a972eb8f872faab3dcfb65034e04938f" <>
                   "6b3410e568",
                 case: :lower
               )
  @v2_envelope Base.decode16!(
                 "02000102030405060708090a0b0c0d0e0f101112131415161718191a1b" <>
                   "63a7042abadead2e525c11c203fe7263393cabfcb91bce6ddb7abefa28b5" <>
                   "e84c9fc05037821acae68113fe28e9431ff4ed3019774ed51df8299f22dc" <>
                   "098dcff2fa92726f00c0ce808272c23084384d05ef4bd71d1d1b90328ad5" <>
                   "463b1bcbad",
                 case: :lower
               )

  describe "derive_key/3 fixed vectors" do
    test "v1 derived key matches the spec vector" do
      assert GpgKeyEnvelope.derive_key(1, @ikm, @salt) == @v1_key
    end

    test "v2 derived key matches the spec vector" do
      assert GpgKeyEnvelope.derive_key(2, @ikm, @salt) == @v2_key
    end

    test "changing one IKM byte changes the derived key" do
      refute GpgKeyEnvelope.derive_key(2, "Test-secret-key-base", @salt) == @v2_key
    end

    test "changing one salt byte changes the derived key" do
      <<first, rest::binary>> = @salt
      refute GpgKeyEnvelope.derive_key(2, @ikm, <<first + 1, rest::binary>>) == @v2_key
    end
  end

  describe "encrypt_with_secret/4 fixed vectors" do
    test "v1 envelope matches the spec vector byte for byte" do
      assert GpgKeyEnvelope.encrypt_with_secret(@plaintext, @user_id, @ikm,
               version: 1,
               salt: @salt,
               nonce: @nonce
             ) == @v1_envelope
    end

    test "v2 envelope matches the spec vector byte for byte" do
      assert GpgKeyEnvelope.encrypt_with_secret(@plaintext, @user_id, @ikm,
               version: 2,
               salt: @salt,
               nonce: @nonce
             ) == @v2_envelope
    end

    test "v2 is the default version" do
      assert GpgKeyEnvelope.encrypt_with_secret(@plaintext, @user_id, @ikm,
               salt: @salt,
               nonce: @nonce
             ) == @v2_envelope
    end
  end

  describe "decrypt_with_secret/3" do
    test "decrypts both spec envelopes" do
      assert {:ok, @plaintext} = GpgKeyEnvelope.decrypt_with_secret(@v1_envelope, @user_id, @ikm)
      assert {:ok, @plaintext} = GpgKeyEnvelope.decrypt_with_secret(@v2_envelope, @user_id, @ikm)
    end

    test "rejects a changed user UUID (AAD binding)" do
      other = "00000000-0000-4000-8000-000000000002"

      assert {:error, :decryption_failed} =
               GpgKeyEnvelope.decrypt_with_secret(@v2_envelope, other, @ikm)
    end

    test "rejects a changed IKM" do
      assert {:error, :decryption_failed} =
               GpgKeyEnvelope.decrypt_with_secret(@v2_envelope, @user_id, "Test-secret-key-base")
    end

    test "rejects tampering with any envelope field" do
      # Flip one bit in each region: salt (offset 1), nonce (17), tag (29),
      # ciphertext (45). Offset 0 is the version byte, tested separately.
      for offset <- [1, 17, 29, 45] do
        <<prefix::binary-size(offset), byte, rest::binary>> = @v2_envelope
        tampered = <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>

        assert {:error, :decryption_failed} =
                 GpgKeyEnvelope.decrypt_with_secret(tampered, @user_id, @ikm),
               "tampering at offset #{offset} was not rejected"
      end
    end

    test "rejects an unsupported version byte" do
      <<_version, rest::binary>> = @v2_envelope

      assert {:error, :unsupported_version} =
               GpgKeyEnvelope.decrypt_with_secret(<<3, rest::binary>>, @user_id, @ikm)
    end

    test "rejects a truncated envelope" do
      assert {:error, :invalid_envelope} =
               GpgKeyEnvelope.decrypt_with_secret(
                 binary_part(@v2_envelope, 0, 40),
                 @user_id,
                 @ikm
               )

      assert {:error, :invalid_envelope} =
               GpgKeyEnvelope.decrypt_with_secret(<<>>, @user_id, @ikm)
    end
  end

  describe "encrypt/2 and decrypt/2 with configured secrets" do
    test "round-trips using the configured secret_key_base with fresh randomness" do
      envelope = GpgKeyEnvelope.encrypt(@plaintext, @user_id)

      assert <<2, _salt::binary-size(16), _nonce::binary-size(12), _rest::binary>> = envelope
      refute envelope == GpgKeyEnvelope.encrypt(@plaintext, @user_id)
      assert {:ok, @plaintext} = GpgKeyEnvelope.decrypt(envelope, @user_id)
    end

    test "decrypt falls back to the previous secret on AEAD failure" do
      envelope = GpgKeyEnvelope.encrypt_with_secret(@plaintext, @user_id, "old-secret-base")

      assert {:error, :decryption_failed} =
               GpgKeyEnvelope.decrypt(envelope, @user_id, secret: "new-secret-base")

      assert {:ok, @plaintext} =
               GpgKeyEnvelope.decrypt(envelope, @user_id,
                 secret: "new-secret-base",
                 previous_secret: "old-secret-base"
               )
    end

    test "unsupported version does not consult the previous secret" do
      envelope = GpgKeyEnvelope.encrypt_with_secret(@plaintext, @user_id, "old-secret-base")
      <<_version, rest::binary>> = envelope

      assert {:error, :unsupported_version} =
               GpgKeyEnvelope.decrypt(<<9, rest::binary>>, @user_id,
                 secret: "new-secret-base",
                 previous_secret: "old-secret-base"
               )
    end
  end
end
