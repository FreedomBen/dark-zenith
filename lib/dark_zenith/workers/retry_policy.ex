defmodule DarkZenith.Workers.RetryPolicy do
  @moduledoc """
  Background Retry Policy (DESIGN.md: Architecture): failed attempt `n`
  (one-indexed) is retried after `min(3600, 30 * 2^(n - 1))` seconds without
  jitter; the twentieth failed attempt is terminal. A syntactically valid
  provider `Retry-After` — delta-seconds or a future HTTP-date — raises the
  delay to `min(86400, max(calculated_delay, provider_delay))`.
  """

  @max_attempts 20

  # HTTP-date to Unix conversion offset (0000-01-01 to 1970-01-01).
  @epoch_gregorian_seconds 62_167_219_200

  # Delta-seconds values beyond a signed 32-bit range are treated as
  # overflowed and ignored; the one-day cap is applied by callers.
  @max_delta_seconds 2_147_483_647

  @doc "Maximum attempts for durable background operations."
  def max_attempts, do: @max_attempts

  @doc "Backoff in seconds before the retry that follows failed attempt `n`."
  def backoff(attempt) when is_integer(attempt) and attempt >= 1 do
    min(3600, 30 * Integer.pow(2, attempt - 1))
  end

  @doc """
  Provider-suggested retry delay in seconds from a `Retry-After` header
  value: a positive integer delta-seconds value, or a future HTTP-date
  (IMF-fixdate plus the obsolete RFC 850 and asctime forms, always GMT) as
  `ceil(date - now)`. Zero, negative, past, overflowed, or malformed values
  yield `nil`.
  """
  def provider_delay(value, now \\ DateTime.utc_now())

  def provider_delay(value, now) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} when seconds > 0 and seconds <= @max_delta_seconds -> seconds
      {_out_of_range, ""} -> nil
      _ -> http_date_delay(trimmed, now)
    end
  end

  def provider_delay(_value, _now), do: nil

  defp http_date_delay(value, now) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_, _, _}, {_, _, _}} = datetime ->
        unix = :calendar.datetime_to_gregorian_seconds(datetime) - @epoch_gregorian_seconds
        # `DateTime.to_unix` floors, so whole-second subtraction implements
        # the documented ceil(date - now).
        delay = unix - DateTime.to_unix(now)
        if delay > 0 and delay <= @max_delta_seconds, do: delay, else: nil

      :bad_date ->
        nil
    end
  rescue
    # convert_request_date is not total over arbitrary input.
    _ -> nil
  end
end
