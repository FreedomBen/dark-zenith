defmodule DarkZenith.Workers.EmailDelivery do
  @moduledoc """
  Oban-backed transactional email delivery (DESIGN.md: Email Delivery).

  Rebuilds the message from its durable job args and delivers through
  `DarkZenith.Mailer`. Transient provider failures retry under Background
  Retry Policy — honoring a syntactically valid provider `Retry-After`
  when the Swoosh error carries one — and exhausted jobs remain visible in
  Oban.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 20

  import Swoosh.Email

  alias DarkZenith.Workers.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    email =
      new()
      |> to(args["to"])
      |> from({args["from_name"], args["from_address"]})
      |> subject(args["subject"])
      |> text_body(args["text_body"])

    case DarkZenith.Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        case provider_delay(reason) do
          nil -> {:error, reason}
          delay -> {:snooze, min(86_400, max(RetryPolicy.backoff(job.attempt), delay))}
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)

  # Positive integer delta-seconds from a provider Retry-After when the
  # Swoosh API-client error exposes response headers; malformed, zero, or
  # negative values are ignored.
  defp provider_delay({_status, %{headers: headers}}) when is_list(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: value
    end)
    |> parse_delay()
  end

  defp provider_delay(_reason), do: nil

  defp parse_delay(nil), do: nil

  defp parse_delay(value) do
    case Integer.parse(to_string(value)) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end
end
