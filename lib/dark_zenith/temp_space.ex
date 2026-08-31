defmodule DarkZenith.TempSpace do
  @moduledoc """
  Node-local temporary-space ledger for RPM processing (DESIGN.md: Package
  Upload & Processing).

  Every worker that invokes RPM tools atomically acquires a lease of
  `3 * source_size + 67108864` bytes before downloading; the claim succeeds
  only when the filesystem's sampled available bytes minus all active
  leases can cover it. Leases are keyed by the durable claim's lease token,
  monitor the acquiring process, and are released on `DOWN` as well as in
  the worker's normal after path. Each claim gets a fresh mode-0700
  directory under the node-local base directory; boot starts with an empty
  ledger and a symlink-safe janitor removes leftover attempt directories.
  A periodic reconciler drops leases whose process is gone.
  """

  use GenServer

  @overhead 67_108_864
  @default_reconcile :timer.seconds(60)

  ## API

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Bytes a claim for `source_size` reserves."
  def reservation_bytes(source_size), do: 3 * source_size + @overhead

  @doc """
  Acquires (or re-enters) the lease for `token`, reserving space for
  `source_size` bytes of input. Returns `{:ok, attempt_dir}` or
  `{:error, :upload_temp_space_unavailable}`.
  """
  def acquire(server \\ __MODULE__, token, source_size) do
    GenServer.call(server, {:acquire, token, source_size, self()})
  end

  @doc "Releases the lease for `token` and removes its attempt directory."
  def release(server \\ __MODULE__, token) do
    GenServer.call(server, {:release, token})
  end

  @doc "Total bytes currently reserved by active leases."
  def reserved_bytes(server \\ __MODULE__) do
    GenServer.call(server, :reserved_bytes)
  end

  ## GenServer

  @impl true
  def init(opts) do
    base_dir =
      Keyword.get_lazy(opts, :base_dir, fn ->
        Application.get_env(:dark_zenith, :rpm_upload_tmpdir) || System.tmp_dir!()
      end)

    File.mkdir_p!(base_dir)
    janitor(base_dir)

    interval = Keyword.get(opts, :reconcile_interval, @default_reconcile)
    if interval, do: Process.send_after(self(), :reconcile, interval)

    {:ok,
     %{
       base_dir: base_dir,
       sampler: Keyword.get(opts, :sampler, &default_sampler/0),
       reconcile_interval: interval,
       # token => %{bytes:, dir:, pid:, monitor:}
       leases: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, token, source_size, pid}, _from, state) do
    case state.leases do
      %{^token => lease} ->
        {:reply, {:ok, lease.dir}, state}

      _ ->
        bytes = reservation_bytes(source_size)
        active = total_reserved(state)
        available = state.sampler.()

        if available - active >= bytes do
          dir = Path.join(state.base_dir, "dz-attempt-#{token}")
          File.mkdir_p!(dir)
          File.chmod!(dir, 0o700)

          lease = %{bytes: bytes, dir: dir, pid: pid, monitor: Process.monitor(pid)}
          {:reply, {:ok, dir}, put_in(state.leases[token], lease)}
        else
          {:reply, {:error, :upload_temp_space_unavailable}, state}
        end
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, drop_lease(state, token)}
  end

  def handle_call(:reserved_bytes, _from, state) do
    {:reply, total_reserved(state), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    token =
      Enum.find_value(state.leases, fn {token, lease} ->
        if lease.monitor == monitor, do: token
      end)

    {:noreply, if(token, do: drop_lease(state, token), else: state)}
  end

  def handle_info(:reconcile, state) do
    stale =
      for {token, lease} <- state.leases, not Process.alive?(lease.pid), do: token

    state = Enum.reduce(stale, state, &drop_lease(&2, &1))

    if state.reconcile_interval do
      Process.send_after(self(), :reconcile, state.reconcile_interval)
    end

    {:noreply, state}
  end

  ## Internals

  defp total_reserved(state) do
    state.leases |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum()
  end

  defp drop_lease(state, token) do
    case Map.pop(state.leases, token) do
      {nil, _} ->
        state

      {lease, leases} ->
        Process.demonitor(lease.monitor, [:flush])
        File.rm_rf(lease.dir)
        %{state | leases: leases}
    end
  end

  # Leftover attempt directories from before a restart cannot be leases; the
  # ledger starts empty, so remove them. `rm_rf` unlinks symlinks rather
  # than following them.
  defp janitor(base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} ->
        for entry <- entries, String.starts_with?(entry, "dz-attempt-") do
          File.rm_rf(Path.join(base_dir, entry))
        end

      _ ->
        :ok
    end

    :ok
  end

  # Sampled available bytes for the base directory's filesystem.
  defp default_sampler do
    base_dir =
      Application.get_env(:dark_zenith, :rpm_upload_tmpdir) || System.tmp_dir!()

    case System.cmd("df", ["--output=avail", "-B1", base_dir], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.trim()
        |> String.to_integer()

      _other ->
        0
    end
  rescue
    _ -> 0
  end
end
