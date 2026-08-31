defmodule DarkZenith.Workers.RetryPolicy do
  @moduledoc """
  Background Retry Policy (DESIGN.md: Architecture): failed attempt `n`
  (one-indexed) is retried after `min(3600, 30 * 2^(n - 1))` seconds without
  jitter; the twentieth failed attempt is terminal.
  """

  @max_attempts 20

  @doc "Maximum attempts for durable background operations."
  def max_attempts, do: @max_attempts

  @doc "Backoff in seconds before the retry that follows failed attempt `n`."
  def backoff(attempt) when is_integer(attempt) and attempt >= 1 do
    min(3600, 30 * Integer.pow(2, attempt - 1))
  end
end
