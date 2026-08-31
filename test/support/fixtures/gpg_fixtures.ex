defmodule DarkZenith.GpgFixtures do
  @moduledoc """
  Generates real GPG key pairs with the system `gpg` for signing tests.
  """

  @doc """
  Generates a key pair. Options: `:algo` (default `"ed25519"`), `:usage`
  (default `"sign"`), `:expire` (default `"never"`), `:passphrase`
  (default none), `:signing_subkeys` (count of signing subkeys added to a
  cert-only primary).
  """
  def generate_key_pair(opts \\ []) do
    algo = Keyword.get(opts, :algo, "ed25519")
    usage = Keyword.get(opts, :usage, "sign")
    expire = Keyword.get(opts, :expire, "never")
    passphrase = Keyword.get(opts, :passphrase, "")
    subkeys = Keyword.get(opts, :signing_subkeys, 0)

    home = Path.join(System.tmp_dir!(), "dz-gpg-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)

    try do
      {_, 0} =
        gpg(home, passphrase, [
          "--quick-gen-key",
          "Fixture Signer <signer#{System.unique_integer([:positive])}@example.com>",
          algo,
          usage,
          expire
        ])

      fingerprint = primary_fingerprint(home)

      for _ <- 1..subkeys//1 do
        {_, 0} = gpg(home, passphrase, ["--quick-add-key", fingerprint, algo, "sign", expire])
      end

      {public, 0} = gpg(home, passphrase, ["--armor", "--export", fingerprint])
      {private, 0} = gpg(home, passphrase, ["--armor", "--export-secret-keys", fingerprint])

      %{public: public, private: private, fingerprint: fingerprint}
    after
      File.rm_rf(home)
    end
  end

  defp primary_fingerprint(home) do
    {output, 0} =
      System.cmd("gpg", ["--homedir", home, "--batch", "--with-colons", "--list-secret-keys"],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":") do
        ["fpr", _, _, _, _, _, _, _, _, fingerprint | _] -> fingerprint
        _ -> nil
      end
    end)
  end

  defp gpg(home, passphrase, args) do
    System.cmd(
      "gpg",
      ["--homedir", home, "--batch", "--no-tty", "--pinentry-mode", "loopback", "--passphrase", passphrase | args],
      stderr_to_stdout: true
    )
  end
end

defmodule DarkZenith.GpgRpmCompatStub do
  @moduledoc """
  Stands in for the rpmsign/rpmkeys fixture-compatibility check in test
  environments without the rpm-sign tool; the real check is
  `DarkZenith.Gpg.RpmCompat`, exercised when `rpmsign` is installed.
  """
  def check(_home, _signing_fingerprint), do: :ok
end
