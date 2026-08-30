defmodule DarkZenith.ObanTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  test "Oban is supervised with the expected queue topology" do
    assert Oban.config().repo == DarkZenith.Repo

    # In test, Oban runs in :manual testing mode with queues disabled, so the
    # queue topology is asserted on the configured environment instead.
    queues = Keyword.fetch!(Application.fetch_env!(:dark_zenith, Oban), :queues)

    for queue <- [:default, :rpm_processing, :metadata, :cleanup, :mailers] do
      assert Keyword.has_key?(queues, queue),
             "expected queue #{inspect(queue)} to be configured"
    end
  end

  test "jobs can be inserted and asserted in manual testing mode" do
    Oban.insert!(Oban.Job.new(%{}, worker: "NoOp", queue: :default))

    assert_enqueued(worker: "NoOp", queue: :default)
  end
end
