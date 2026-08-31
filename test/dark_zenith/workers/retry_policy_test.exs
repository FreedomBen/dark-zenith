defmodule DarkZenith.Workers.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias DarkZenith.Workers.RetryPolicy

  @now ~U[2026-08-31 12:00:00Z]

  describe "backoff/1" do
    test "doubles from 30 seconds and caps at one hour" do
      for {attempt, expected} <- [{1, 30}, {2, 60}, {8, 3600}, {20, 3600}] do
        assert RetryPolicy.backoff(attempt) == expected
      end
    end
  end

  describe "provider_delay/2 with delta-seconds" do
    test "accepts a positive integer delta" do
      assert RetryPolicy.provider_delay("120", @now) == 120
      assert RetryPolicy.provider_delay("1", @now) == 1
    end

    test "ignores zero, negative, overflowed, and malformed deltas" do
      for value <- ["0", "-5", "12.5", "12 seconds", "", "  ", "99999999999", nil, 120] do
        assert RetryPolicy.provider_delay(value, @now) == nil, inspect(value)
      end
    end
  end

  describe "provider_delay/2 with an HTTP-date" do
    test "a future IMF-fixdate yields ceil(date - now)" do
      assert RetryPolicy.provider_delay("Mon, 31 Aug 2026 12:02:00 GMT", @now) == 120
    end

    test "the obsolete RFC 850 and asctime forms are accepted" do
      assert RetryPolicy.provider_delay("Monday, 31-Aug-26 12:02:00 GMT", @now) == 120
      assert RetryPolicy.provider_delay("Mon Aug 31 12:02:00 2026", @now) == 120
    end

    test "a fractional now still rounds the delay up" do
      now = ~U[2026-08-31 12:00:00.400Z]
      assert RetryPolicy.provider_delay("Mon, 31 Aug 2026 12:00:02 GMT", now) == 2
    end

    test "past, now-equal, and malformed dates are ignored" do
      for value <- [
            "Mon, 31 Aug 2026 11:59:00 GMT",
            "Mon, 31 Aug 2026 12:00:00 GMT",
            "Mon, 99 Aug 2026 12:00:00 GMT",
            "yesterday"
          ] do
        assert RetryPolicy.provider_delay(value, @now) == nil, inspect(value)
      end
    end
  end
end
