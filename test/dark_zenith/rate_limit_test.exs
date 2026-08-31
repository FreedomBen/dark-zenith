defmodule DarkZenith.RateLimitTest do
  # Not async: adjusts the global rate-limit overrides.
  use ExUnit.Case, async: false

  alias DarkZenith.RateLimit

  defp unique_id, do: {:test, System.unique_integer([:positive])}

  test "windows are UTC-aligned and the last slot is admitted" do
    identity = unique_id()
    # general_unauth override in test is {1_000_000, 60}; use a raw window
    # via repeated hits against a tight custom kind through overrides.
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)

    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.put(previous, :general_unauth, {2, 60})
    )

    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)

    now = 1_756_000_000
    window_end = (div(now, 60) + 1) * 60

    assert {true, %{remaining: 1, reset: ^window_end, limit: 2}} =
             RateLimit.hit([{:general_unauth, identity}], now)

    # The request consuming the last slot succeeds with zero remaining.
    assert {true, %{remaining: 0}} = RateLimit.hit([{:general_unauth, identity}], now)
    assert {false, %{remaining: 0}} = RateLimit.hit([{:general_unauth, identity}], now)

    # A new wall-clock window resets the counter.
    assert {true, _} = RateLimit.hit([{:general_unauth, identity}], window_end)
  end

  test "the governing bucket has the smallest remaining allowance" do
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)

    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      previous |> Map.put(:general_auth, {100, 60}) |> Map.put(:api_key_create, {2, 3600})
    )

    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)

    id = unique_id()

    {true, governing} = RateLimit.hit([{:general_auth, id}, {:api_key_create, id}])
    assert governing.limit == 2
    assert governing.remaining == 1
  end

  test "simultaneous increments are atomic" do
    previous = Application.get_env(:dark_zenith, :rate_limit_overrides)

    Application.put_env(
      :dark_zenith,
      :rate_limit_overrides,
      Map.put(previous, :general_unauth, {50, 60})
    )

    on_exit(fn -> Application.put_env(:dark_zenith, :rate_limit_overrides, previous) end)

    identity = unique_id()
    now = 1_756_000_000

    results =
      1..80
      |> Enum.map(fn _ ->
        Task.async(fn -> RateLimit.hit([{:general_unauth, identity}], now) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({true, _}, &1)) == 50
    assert Enum.count(results, &match?({false, _}, &1)) == 30
  end

  test "the sweep removes only expired windows" do
    identity = unique_id()
    now = 1_756_000_000

    RateLimit.hit([{:general_unauth, identity}], now)
    RateLimit.hit([{:general_unauth, identity}], now + 60)

    # Sweeping at the first window's reset removes it but keeps the second.
    RateLimit.sweep((div(now, 60) + 1) * 60)

    entries =
      :ets.select(DarkZenith.RateLimit, [
        {{{:general_unauth, identity, :"$1"}, :_, :_}, [], [:"$1"]}
      ])

    assert entries == [div(now + 60, 60)]
  end
end

defmodule DarkZenith.ClientIpTest do
  use ExUnit.Case, async: false

  alias DarkZenith.ClientIp

  defp conn_with(peer, headers) do
    conn = %{Phoenix.ConnTest.build_conn() | remote_ip: peer}
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp trust!(cidrs) do
    Application.put_env(:dark_zenith, :trusted_proxies, ClientIp.parse_trusted_proxies(cidrs))
    on_exit(fn -> Application.delete_env(:dark_zenith, :trusted_proxies) end)
  end

  test "an empty trust list ignores all forwarded headers" do
    conn =
      conn_with({10, 0, 0, 1}, [
        {"cf-connecting-ip", "203.0.113.5"},
        {"x-forwarded-for", "203.0.113.5"}
      ])

    assert ClientIp.resolve(conn) == {10, 0, 0, 1}
  end

  test "a trusted peer's CF-Connecting-IP wins over the forwarded chain" do
    trust!("10.0.0.0/8")

    conn =
      conn_with({10, 0, 0, 1}, [
        {"cf-connecting-ip", "203.0.113.5"},
        {"x-forwarded-for", "198.51.100.7, 10.0.0.2"}
      ])

    assert ClientIp.resolve(conn) == {203, 0, 113, 5}
  end

  test "the forwarded chain walks right to left skipping trusted hops" do
    trust!("10.0.0.0/8")

    conn =
      conn_with({10, 0, 0, 1}, [
        {"x-forwarded-for", "198.51.100.7, 203.0.113.9, 10.0.0.2"}
      ])

    assert ClientIp.resolve(conn) == {203, 0, 113, 9}

    all_trusted = conn_with({10, 0, 0, 1}, [{"x-forwarded-for", "10.0.0.9, 10.0.0.2"}])
    assert ClientIp.resolve(all_trusted) == {10, 0, 0, 1}

    junk = conn_with({10, 0, 0, 1}, [{"x-forwarded-for", "not-an-ip"}])
    assert ClientIp.resolve(junk) == {10, 0, 0, 1}
  end

  test "IPv6 identities collapse to the /64 prefix" do
    a = {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}
    b = {0x2001, 0xDB8, 1, 2, 0xFFFF, 0, 0, 9}
    c = {0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}

    assert ClientIp.bucket_identity(a) == ClientIp.bucket_identity(b)
    refute ClientIp.bucket_identity(a) == ClientIp.bucket_identity(c)
  end
end
