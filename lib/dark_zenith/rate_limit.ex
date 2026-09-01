defmodule DarkZenith.RateLimit do
  @moduledoc """
  ETS fixed-window rate limiting (DESIGN.md: Rate Limiting).

  Windows are UTC-aligned: the bucket number is
  `floor(unix_seconds / window_seconds)`, so one-minute buckets reset on
  wall-clock minutes and one-hour buckets on wall-clock hours. Counters
  live under `{kind, identity, window_number}` keys with atomic
  post-increment: a count at or below the limit is admitted, so the
  request consuming the last slot succeeds with zero remaining. A 60-second
  sweep removes entries whose reset has passed; it never trusts
  attacker-controlled timestamps.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.seconds(60)

  @default_limits %{
    general_auth: {600, 60},
    general_unauth: {120, 60},
    auth_attempt_ip: {10, 60},
    auth_attempt_email: {10, 60},
    download_unauth: {600, 60},
    download_auth: {1200, 60},
    search_auth: {120, 60},
    search_unauth: {30, 60},
    upload_intent: {60, 3600},
    repo_create: {30, 3600},
    api_key_create: {30, 3600},
    gpg_key_mutation: {10, 3600},
    collaborator_add: {60, 3600},
    email_change: {10, 3600}
  }

  ## API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The `{limit, window_seconds}` for a bucket kind (test-overridable)."
  def limit_for(kind) do
    overrides = Application.get_env(:dark_zenith, :rate_limit_overrides, %{})
    Map.get(overrides, kind) || Map.fetch!(@default_limits, kind)
  end

  @doc """
  Atomically consumes one slot in each `{kind, identity}` bucket and
  returns `{allowed?, governing}` where `governing` is the bucket state
  (`%{limit, remaining, reset}`) with the smallest remaining allowance
  (ties: earliest reset, then lower limit). Every listed bucket is consumed
  even when another rejects.
  """
  def hit(buckets, now_unix \\ System.os_time(:second)) when is_list(buckets) do
    states =
      for {kind, identity} <- buckets do
        {limit, window} = limit_for(kind)
        window_number = div(now_unix, window)
        reset = (window_number + 1) * window
        key = {kind, identity, window_number}

        count = :ets.update_counter(@table, key, {2, 1}, {key, 0, reset})

        %{
          allowed?: count <= limit,
          limit: limit,
          remaining: max(limit - count, 0),
          reset: reset
        }
      end

    governing =
      Enum.min_by(states, fn state -> {state.remaining, state.reset, state.limit} end)

    {Enum.all?(states, & &1.allowed?), governing}
  end

  @doc "Removes every entry whose window reset is at or before `now`."
  def sweep(now_unix \\ System.os_time(:second)) do
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now_unix}], [true]}
    ])
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      decentralized_counters: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
