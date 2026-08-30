defmodule DarkZenith.CryptoTest do
  use ExUnit.Case, async: true

  alias DarkZenith.Crypto

  describe "token_hash/2" do
    test "computes HMAC-SHA-256 of the full token string as lowercase hex" do
      secret = "super-secret-key-base"
      token = "dzak_AbCdEfGh0123456789"

      expected =
        :crypto.mac(:hmac, :sha256, secret, token)
        |> Base.encode16(case: :lower)

      assert Crypto.token_hash(secret, token) == expected
      assert String.length(Crypto.token_hash(secret, token)) == 64
      assert Crypto.token_hash(secret, token) =~ ~r/^[0-9a-f]{64}$/
    end

    test "the prefix is part of the hashed value" do
      secret = "super-secret-key-base"

      refute Crypto.token_hash(secret, "dzak_same-secret") ==
               Crypto.token_hash(secret, "dzst_same-secret")
    end

    test "different secrets produce different hashes" do
      refute Crypto.token_hash("secret-one", "dzak_token") ==
               Crypto.token_hash("secret-two", "dzak_token")
    end

    test "token_hash/1 uses the configured secret_key_base" do
      configured = Application.fetch_env!(:dark_zenith, :secret_key_base)

      assert Crypto.token_hash("dzst_abc") == Crypto.token_hash(configured, "dzst_abc")
    end
  end

  describe "validate_secret_key_base/1" do
    test "accepts values of at least 64 raw bytes" do
      assert :ok = Crypto.validate_secret_key_base(String.duplicate("a", 64))
      assert :ok = Crypto.validate_secret_key_base(String.duplicate("a", 100))
    end

    test "rejects values under 64 raw bytes" do
      assert {:error, _} = Crypto.validate_secret_key_base(String.duplicate("a", 63))
      assert {:error, _} = Crypto.validate_secret_key_base("")
    end

    test "counts raw UTF-8 bytes, not characters" do
      # 32 two-byte characters = 64 bytes
      assert :ok = Crypto.validate_secret_key_base(String.duplicate("é", 32))
      # 63 bytes: 31 two-byte characters plus one single-byte character
      assert {:error, _} = Crypto.validate_secret_key_base(String.duplicate("é", 31) <> "a")
    end

    test "rejects non-binary values" do
      assert {:error, _} = Crypto.validate_secret_key_base(nil)
    end
  end

  describe "validate_secret_key_bases/2" do
    @current String.duplicate("c", 64)
    @previous String.duplicate("p", 64)

    test "accepts a valid current with no previous" do
      assert :ok = Crypto.validate_secret_key_bases(@current, nil)
    end

    test "accepts a valid, distinct previous" do
      assert :ok = Crypto.validate_secret_key_bases(@current, @previous)
    end

    test "rejects a previous equal to current" do
      assert {:error, _} = Crypto.validate_secret_key_bases(@current, @current)
    end

    test "rejects a previous under 64 bytes" do
      assert {:error, _} = Crypto.validate_secret_key_bases(@current, String.duplicate("p", 63))
    end

    test "rejects an invalid current regardless of previous" do
      assert {:error, _} = Crypto.validate_secret_key_bases("short", nil)
    end
  end
end
