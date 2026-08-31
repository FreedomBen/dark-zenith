defmodule DarkZenith.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias DarkZenith.ToolRunner

  test "returns output and exit status like System.cmd" do
    assert {"hi\n", 0} = ToolRunner.cmd("echo", ["hi"])
    assert {_output, status} = ToolRunner.cmd("false", [])
    assert status == 1
  end

  test "merges stderr and passes environment" do
    {output, 0} = ToolRunner.cmd("sh", ["-c", "echo err >&2; echo ${DZ_TOOL_TEST}"], env: [{"DZ_TOOL_TEST", "v"}])
    assert output =~ "err"
    assert output =~ "v"
  end

  test "kills the whole process group on deadline" do
    started = System.monotonic_time(:millisecond)

    # The child spawns its own grandchild; the group kill must reap both.
    assert {:error, :timeout} =
             ToolRunner.cmd("sh", ["-c", "sleep 30 & sleep 30"], timeout_ms: 300)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5_000
  end

  test "a halted heartbeat kills the group" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             ToolRunner.cmd("sleep", ["30"],
               timeout_ms: 60_000,
               heartbeat: {100, fn -> :halt end}
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5_000
  end

  test "a healthy heartbeat lets the tool finish" do
    parent = self()

    assert {"ok\n", 0} =
             ToolRunner.cmd("sh", ["-c", "sleep 0.3; echo ok"],
               timeout_ms: 10_000,
               heartbeat:
                 {100,
                  fn ->
                    send(parent, :beat)
                    :ok
                  end}
             )

    assert_received :beat
  end
end

defmodule DarkZenith.TempSpaceJanitorTest do
  use ExUnit.Case, async: true

  alias DarkZenith.TempSpace

  setup do
    base = Path.join(System.tmp_dir!(), "dz-janitor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    server =
      start_supervised!(
        {TempSpace, name: :"janitor_#{System.unique_integer([:positive])}", base_dir: base, sampler: fn -> 10_000_000_000 end}
      )

    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, server: server}
  end

  defp age!(path) do
    old = System.os_time(:second) - 7200
    File.touch!(path, old)
  end

  test "removes only stale unleased attempt directories", ctx do
    token = Ecto.UUID.generate()
    {:ok, leased_dir} = TempSpace.acquire(ctx.server, token, 100)
    age!(leased_dir)

    stale = Path.join(ctx.base, "dz-attempt-#{Ecto.UUID.generate()}")
    File.mkdir_p!(stale)
    age!(stale)

    fresh = Path.join(ctx.base, "dz-attempt-#{Ecto.UUID.generate()}")
    File.mkdir_p!(fresh)

    unrelated = Path.join(ctx.base, "other-file")
    File.write!(unrelated, "keep")
    age!(unrelated)

    assert {:ok, 1} = TempSpace.hourly_janitor(ctx.server)

    assert File.exists?(leased_dir), "a current lease's directory survives"
    refute File.exists?(stale)
    assert File.exists?(fresh), "younger than one hour survives"
    assert File.exists?(unrelated), "non-attempt paths are never touched"
  end

  test "does not follow symlinks out of the base directory", ctx do
    outside = Path.join(System.tmp_dir!(), "dz-janitor-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "victim"), "data")
    on_exit(fn -> File.rm_rf(outside) end)

    link = Path.join(ctx.base, "dz-attempt-#{Ecto.UUID.generate()}")
    File.ln_s!(outside, link)
    age!(link)

    assert {:ok, 1} = TempSpace.hourly_janitor(ctx.server)

    refute File.exists?(link) or File.lstat(link) != {:error, :enoent}
    assert File.exists?(Path.join(outside, "victim")), "symlink target contents survive"
  end
end
