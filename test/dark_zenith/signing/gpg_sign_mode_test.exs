defmodule DarkZenith.Signing.GpgSignModeTest do
  @moduledoc """
  rpmsign mode selection (DESIGN.md: RPM signing step 4): unsigned RPMs are
  signed with `--addsign`; RPMs already carrying an OpenPGP package
  signature are signed with `--resign`. The native tools are replaced with
  recording stubs so only argument construction is under test.
  """

  # Not async: overrides the native tool path configuration.
  use DarkZenith.DataCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Accounts.User
  alias DarkZenith.Rpm.Tags

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # The key is uploaded with the real gpg before the tool paths are
    # swapped for stubs.
    pair = generate_key_pair()
    user = user_fixture()
    {:ok, _} = Accounts.upsert_gpg_key(user, pair.public, pair.private)
    owner = Repo.get!(User, user.id)

    args_file = Path.join(tmp_dir, "rpmsign-args")

    stub! = fn name, script ->
      path = Path.join(tmp_dir, name)
      File.write!(path, script)
      File.chmod!(path, 0o755)
      path
    end

    gpg_stub = stub!.("gpg", "#!/bin/sh\nexit 0\n")
    rpmsign_stub = stub!.("rpmsign", "#!/bin/sh\necho \"$@\" > #{args_file}\nexit 0\n")

    rpmkeys_stub =
      stub!.(
        "rpmkeys",
        "#!/bin/sh\nprintf '    sha256 digest: OK\\n    key signature: OK\\n'\nexit 0\n"
      )

    previous =
      for key <- [:gpg_path, :rpmsign_path, :rpmkeys_path] do
        {key, Application.get_env(:dark_zenith, key)}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:dark_zenith, key)
        {key, value} -> Application.put_env(:dark_zenith, key, value)
      end)
    end)

    Application.put_env(:dark_zenith, :gpg_path, gpg_stub)
    Application.put_env(:dark_zenith, :rpmsign_path, rpmsign_stub)
    Application.put_env(:dark_zenith, :rpmkeys_path, rpmkeys_stub)

    %{owner: owner, args_file: args_file}
  end

  defp sign!(ctx, binary, workname) do
    {:ok, metadata} = DarkZenith.Rpm.parse(binary)

    workdir = Path.join(Path.dirname(ctx.args_file), workname)
    File.mkdir_p!(workdir)
    source = Path.join(workdir, "source.rpm")
    File.write!(source, binary)

    assert {:ok, _signed} = DarkZenith.Signing.Gpg.sign_rpm(ctx.owner, source, workdir, metadata)
    File.read!(ctx.args_file)
  end

  test "an unsigned source selects --addsign", ctx do
    args = sign!(ctx, minimal_binary(), "unsigned")

    assert args =~ "--addsign"
    refute args =~ "--resign"
  end

  test "a source with an existing OpenPGP package signature selects --resign", ctx do
    binary = minimal_binary()
    md5_index = find_entry(binary, 96, Tags.sig_md5())
    assert md5_index
    signed_source = patch_entry(binary, 96, md5_index, tag: Tags.sig_pgp())

    args = sign!(ctx, signed_source, "presigned")

    assert args =~ "--resign"
    refute args =~ "--addsign"
  end

  test "a v6 source adds --rpmv4", ctx do
    args = sign!(ctx, v6_binary(), "v6")

    assert args =~ "--rpmv4"
    assert args =~ "--addsign"
  end
end
