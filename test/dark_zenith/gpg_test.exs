defmodule DarkZenith.GpgTest do
  use ExUnit.Case, async: true

  import DarkZenith.GpgFixtures

  alias DarkZenith.Gpg

  describe "validate_key_pair/2 acceptance" do
    test "accepts an Ed25519 signing primary with no expiry" do
      pair = generate_key_pair()

      assert {:ok, info} = Gpg.validate_key_pair(pair.public, pair.private)
      assert info.primary_fingerprint == pair.fingerprint
      assert info.signing_fingerprint == pair.fingerprint
      assert info.expires_at == nil
    end

    test "accepts ECDSA P-256 and records a far-enough expiry" do
      pair = generate_key_pair(algo: "nistp256", expire: "90d")

      assert {:ok, info} = Gpg.validate_key_pair(pair.public, pair.private)

      expected = DateTime.add(DateTime.utc_now(), 90, :day)
      assert_in_delta DateTime.to_unix(info.expires_at), DateTime.to_unix(expected), 3600
    end

    test "selects the only usable signing subkey of a cert-only primary" do
      pair = generate_key_pair(usage: "cert", signing_subkeys: 1)

      assert {:ok, info} = Gpg.validate_key_pair(pair.public, pair.private)
      assert info.primary_fingerprint == pair.fingerprint
      assert info.signing_fingerprint != pair.fingerprint
      assert byte_size(info.signing_fingerprint) == 40
    end
  end

  describe "validate_key_pair/2 rejection" do
    test "rejects multiple usable signing subkeys as ambiguous" do
      pair = generate_key_pair(usage: "cert", signing_subkeys: 2)
      assert {:error, :validation_failed} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects a cert-only key with no signing capability" do
      pair = generate_key_pair(usage: "cert")
      assert {:error, :validation_failed} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects disallowed algorithms" do
      pair = generate_key_pair(algo: "rsa2048")
      assert {:error, :validation_failed} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "accepts RSA-3072" do
      pair = generate_key_pair(algo: "rsa3072")
      assert {:ok, _} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects an expiry under thirty days away" do
      pair = generate_key_pair(expire: "10d")
      assert {:error, :validation_failed} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects passphrase-protected private keys" do
      pair = generate_key_pair(passphrase: "supersecretpass")
      assert {:error, :validation_failed} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects mismatched pairs and garbage armor" do
      a = generate_key_pair()
      b = generate_key_pair()

      assert {:error, :validation_failed} = Gpg.validate_key_pair(a.public, b.private)
      assert {:error, :validation_failed} = Gpg.validate_key_pair("not armor", a.private)
    end
  end

  describe "sign_detached/3" do
    test "produces a verifiable armored signature with the exact key" do
      pair = generate_key_pair()
      payload = "<repomd>content</repomd>\n"

      assert {:ok, signature} = Gpg.sign_detached(pair.private, pair.fingerprint, payload)
      assert signature =~ "BEGIN PGP SIGNATURE"

      assert :ok = Gpg.verify_detached(pair.public, payload, signature)

      assert {:error, :bad_signature} =
               Gpg.verify_detached(pair.public, payload <> "x", signature)
    end
  end

  describe "generate_key_pair/2" do
    test "generates an Ed25519 pair that passes the full upload validation pipeline" do
      uid =
        "Dark Zenith repository signing <gen-#{System.unique_integer([:positive])}@example.com>"

      assert {:ok, pair} = Gpg.generate_key_pair("ed25519", uid)

      assert pair.public =~ "BEGIN PGP PUBLIC KEY BLOCK"
      assert pair.private =~ "BEGIN PGP PRIVATE KEY BLOCK"

      assert {:ok, info} = Gpg.validate_key_pair(pair.public, pair.private)
      # A sign-capable primary with no subkeys: the primary is the signer.
      assert info.primary_fingerprint == info.signing_fingerprint
      assert info.expires_at == nil
    end

    test "the generated key carries the requested UID snapshot" do
      uid = "Dark Zenith repository signing <uid-snap@example.com>"
      assert {:ok, pair} = Gpg.generate_key_pair("ed25519", uid)

      path =
        Path.join(System.tmp_dir!(), "dz-uid-check-#{System.unique_integer([:positive])}.asc")

      File.write!(path, pair.public)

      try do
        {listing, 0} =
          System.cmd("gpg", ["--batch", "--with-colons", "--show-keys", path],
            stderr_to_stdout: true
          )

        assert listing =~ "uid-snap@example.com"
        assert listing =~ "Dark Zenith repository signing"
      after
        File.rm(path)
      end
    end

    test "honors an allowlisted non-default algorithm" do
      assert {:ok, pair} = Gpg.generate_key_pair("nistp256", "Alt <alt@example.com>")
      assert {:ok, _info} = Gpg.validate_key_pair(pair.public, pair.private)
    end

    test "rejects algorithms outside the allowlist without generating" do
      assert {:error, :validation_failed} =
               Gpg.generate_key_pair("rsa2048", "Bad <bad@example.com>")

      assert {:error, :validation_failed} =
               Gpg.generate_key_pair("brainpoolP256r1", "Bad <bad@example.com>")
    end
  end

  describe "RPM signing compatibility" do
    @tag :rpmsign
    test "the real fixture check passes for an accepted key when rpmsign exists" do
      pair = generate_key_pair()

      home = Path.join(System.tmp_dir!(), "dz-compat-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      File.chmod!(home, 0o700)

      try do
        key_path = Path.join(home, "private.asc")
        File.write!(key_path, pair.private)

        {_, 0} =
          System.cmd("gpg", ["--homedir", home, "--batch", "--import", key_path],
            stderr_to_stdout: true
          )

        assert :ok = DarkZenith.Gpg.RpmCompat.check(home, pair.fingerprint)
      after
        File.rm_rf(home)
      end
    end
  end
end
