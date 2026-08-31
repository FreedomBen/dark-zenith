defmodule DarkZenith.Workers.EmailDeliveryTest do
  # Not async: swaps the Mailer adapter to a failing stub.
  use DarkZenith.DataCase, async: false
  use Oban.Testing, repo: DarkZenith.Repo

  alias DarkZenith.Workers.EmailDelivery

  defmodule RetryAfterAdapter do
    @moduledoc "Always fails with the headers stashed in the test process."
    @behaviour Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, {429, %{headers: Process.get(:mail_headers, [])}}}

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def validate_dependency, do: :ok
  end

  setup do
    previous = Application.get_env(:dark_zenith, DarkZenith.Mailer)
    Application.put_env(:dark_zenith, DarkZenith.Mailer, adapter: RetryAfterAdapter)
    on_exit(fn -> Application.put_env(:dark_zenith, DarkZenith.Mailer, previous) end)
    :ok
  end

  defp args do
    %{
      "to" => "someone@example.com",
      "from_name" => "Dark Zenith",
      "from_address" => "noreply@example.com",
      "subject" => "Subject",
      "text_body" => "Body"
    }
  end

  test "a provider Retry-After delta snoozes at least that long" do
    Process.put(:mail_headers, [{"Retry-After", "7200"}])

    assert {:snooze, 7200} = perform_job(EmailDelivery, args(), attempt: 1)
  end

  test "a provider Retry-After HTTP-date snoozes until that time, capped at one day" do
    future = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)

    Process.put(:mail_headers, [
      {"Retry-After", Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")}
    ])

    assert {:snooze, 86_400} = perform_job(EmailDelivery, args(), attempt: 1)
  end

  test "the calculated backoff wins over a smaller provider delay" do
    Process.put(:mail_headers, [{"Retry-After", "1"}])

    # Attempt 8 backoff is 3600.
    assert {:snooze, 3600} = perform_job(EmailDelivery, args(), attempt: 8)
  end

  test "malformed or absent Retry-After falls back to the plain error" do
    for headers <- [[], [{"Retry-After", "soon"}], [{"Retry-After", "-1"}]] do
      Process.put(:mail_headers, headers)
      assert {:error, {429, _}} = perform_job(EmailDelivery, args(), attempt: 1)
    end
  end
end
