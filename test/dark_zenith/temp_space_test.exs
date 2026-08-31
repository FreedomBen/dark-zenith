defmodule DarkZenith.TempSpaceTest do
  use ExUnit.Case, async: false

  alias DarkZenith.TempSpace

  # 3 * source + 64 MiB
  @overhead 67_108_864

  defp start_ledger(free_bytes) do
    name = :"temp_space_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TempSpace, name: name, sampler: fn -> free_bytes end, reconcile_interval: :timer.hours(1)}
    )

    name
  end

  test "reserves 3x source plus overhead against sampled free bytes" do
    ledger = start_ledger(@overhead + 3_000)

    assert {:ok, dir} = TempSpace.acquire(ledger, "token-a", 1_000)
    assert File.dir?(dir)
    assert TempSpace.reserved_bytes(ledger) == @overhead + 3_000

    # No capacity left for even a tiny second claim.
    assert {:error, :upload_temp_space_unavailable} = TempSpace.acquire(ledger, "token-b", 1)

    TempSpace.release(ledger, "token-a")
    assert TempSpace.reserved_bytes(ledger) == 0
    refute File.dir?(dir)

    assert {:ok, _dir} = TempSpace.acquire(ledger, "token-b", 1)
  end

  test "the atomic ledger never overcommits under concurrent claims" do
    # Capacity for exactly two claims of source size 1000.
    ledger = start_ledger(2 * (@overhead + 3_000))
    parent = self()

    tasks =
      for i <- 1..6 do
        Task.async(fn ->
          result = TempSpace.acquire(ledger, "token-#{i}", 1_000)
          send(parent, {:acquired, i, result})
          result
        end)
      end

    results = Task.await_many(tasks)
    granted = Enum.count(results, &match?({:ok, _}, &1))
    denied = Enum.count(results, &match?({:error, :upload_temp_space_unavailable}, &1))

    assert granted == 2
    assert denied == 4
  end

  test "a crashed holder's lease is reclaimed and a later claim proceeds" do
    ledger = start_ledger(@overhead + 3_000)

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, _dir} = TempSpace.acquire(ledger, "crash-token", 1_000)
        exit(:boom)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

    # The monitor releases the lease; poll briefly for the DOWN to process.
    assert poll_until(fn -> TempSpace.reserved_bytes(ledger) == 0 end)
    assert {:ok, _dir} = TempSpace.acquire(ledger, "next-token", 1_000)
  end

  test "acquiring the same token twice returns the same directory" do
    ledger = start_ledger(10 * @overhead)
    assert {:ok, dir} = TempSpace.acquire(ledger, "token", 1)
    assert {:ok, ^dir} = TempSpace.acquire(ledger, "token", 1)
    assert TempSpace.reserved_bytes(ledger) == @overhead + 3
  end

  test "the boot janitor removes leftover attempt directories" do
    base =
      Path.join(System.tmp_dir!(), "dz-temp-space-janitor-#{System.unique_integer([:positive])}")

    leftover = Path.join(base, "dz-attempt-stale")
    File.mkdir_p!(leftover)
    File.write!(Path.join(leftover, "junk"), "x")

    name = :"temp_space_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TempSpace,
       name: name,
       sampler: fn -> 10 * @overhead end,
       base_dir: base,
       reconcile_interval: :timer.hours(1)}
    )

    refute File.exists?(leftover)
  end

  defp poll_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        poll_until(fun, attempts - 1)
    end
  end
end
