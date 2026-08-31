defmodule DarkZenith.ToolRunner do
  @moduledoc """
  Runs native tools (`rpmkeys`, `rpmsign`, `gpg`) in their own process
  group with a hard `RPM_TOOL_TIMEOUT_SECONDS` deadline (DESIGN.md: Signing
  Transition Items). On deadline (or a halted heartbeat) it sends `TERM` to
  the group, waits 10 seconds, and sends `KILL` if needed, so a hung or
  superseded native tool cannot run forever.

  The child is started through `setsid`, which makes it the leader of a
  fresh process group; killing `-pgid` therefore reaps the tool and any
  helpers it spawned.
  """

  @term_grace_ms 10_000

  @doc """
  Runs `executable` with `args`, returning `{output, exit_status}` like
  `System.cmd/3` (stderr merged), or `{:error, :timeout}` after a group
  kill. Options: `:timeout_ms` (default `RPM_TOOL_TIMEOUT_SECONDS`),
  `:env` (list of `{name, value}`), `:heartbeat` (`{interval_ms, fun}` —
  the fun renews the caller's lease and returns `:ok` to continue or
  `:halt` to kill the group because the lease is gone).
  """
  def cmd(executable, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())
    env = Keyword.get(opts, :env, [])
    heartbeat = Keyword.get(opts, :heartbeat)

    exe_path = System.find_executable(executable) || raise ArgumentError, "#{executable} not found"

    # `setsid --wait` forks a session/group leader and propagates its exit
    # status; the group id is the forked child's pid, resolved via ps.
    setsid = System.find_executable("setsid")

    {spawn_path, spawn_args} =
      if setsid, do: {setsid, ["--wait", exe_path | args]}, else: {exe_path, args}

    port =
      Port.open({:spawn_executable, spawn_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: spawn_args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    kill_target = if setsid, do: {:setsid_parent, os_pid}, else: {:direct, os_pid}

    tick_ref = schedule_tick(heartbeat)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, kill_target, deadline, heartbeat, tick_ref, [])
    after
      if tick_ref, do: Process.cancel_timer(tick_ref)
      flush_tick()
    end
  end

  defp collect(port, kill_target, deadline, heartbeat, tick_ref, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill(port, kill_target)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          collect(port, kill_target, deadline, heartbeat, tick_ref, [acc | [data]])

        {^port, {:exit_status, status}} ->
          {IO.iodata_to_binary(acc), status}

        {__MODULE__, :tick} ->
          case heartbeat do
            {interval_ms, fun} ->
              case fun.() do
                :ok ->
                  tick_ref = Process.send_after(self(), {__MODULE__, :tick}, interval_ms)
                  collect(port, kill_target, deadline, heartbeat, tick_ref, acc)

                :halt ->
                  # The lease was canceled or superseded: the replacement
                  # state is already authoritative, discard the attempt.
                  kill(port, kill_target)
                  {:error, :timeout}
              end

            nil ->
              collect(port, kill_target, deadline, heartbeat, tick_ref, acc)
          end
      after
        min(remaining, 1_000) ->
          collect(port, kill_target, deadline, heartbeat, tick_ref, acc)
      end
    end
  end

  defp schedule_tick({interval_ms, _fun}),
    do: Process.send_after(self(), {__MODULE__, :tick}, interval_ms)

  defp schedule_tick(nil), do: nil

  defp flush_tick do
    receive do
      {__MODULE__, :tick} -> flush_tick()
    after
      0 -> :ok
    end
  end

  # Resolved lazily at kill time: a hung tool is alive, so its pgid (the
  # setsid-forked leader's pid) is discoverable via ps; a child that
  # already exited needs no kill. Signaling the parent's own group would
  # hit the BEAM, so an unresolved group is never signaled.
  defp resolve_group(nil), do: nil

  defp resolve_group(parent_pid) do
    case System.cmd("ps", ["-o", "pgid=", "--ppid", Integer.to_string(parent_pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pgid, _} -> pgid
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp kill(port, {:setsid_parent, os_pid}) do
    case resolve_group(os_pid) do
      nil ->
        :ok

      group_pid ->
        signal(-group_pid, "TERM")
        await_exit(port, @term_grace_ms)
        signal(-group_pid, "KILL")
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  # Without setsid there is no dedicated group: signal only the tool itself.
  defp kill(port, {:direct, os_pid}) do
    if os_pid do
      signal(os_pid, "TERM")
      await_exit(port, @term_grace_ms)
      signal(os_pid, "KILL")
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  defp await_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      grace_ms -> :timeout
    end
  end

  # A negative pid addresses the whole process group.
  defp signal(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    ErlangError -> :ok
  end

  defp default_timeout_ms do
    Application.get_env(:dark_zenith, :rpm_tool_timeout_seconds, 1800) * 1000
  end
end
