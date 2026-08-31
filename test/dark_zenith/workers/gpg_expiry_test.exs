defmodule DarkZenith.Workers.GpgExpiryTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import Swoosh.TestAssertions

  alias DarkZenith.Accounts.User
  alias DarkZenith.Workers.{GpgExpiryMail, GpgExpiryScan}

  defp put_expiring_key!(user, days) do
    expires = DateTime.add(DateTime.utc_now(:second), days, :day)
    fingerprint = String.duplicate("B", 40)

    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [
          gpg_key_private: <<2, 0>>,
          gpg_key_public: "pub",
          gpg_key_fingerprint: fingerprint,
          gpg_signing_fingerprint: fingerprint,
          gpg_key_expires_at: expires
        ]
      )

    {fingerprint, expires}
  end

  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  test "the scan queues only crossed, un-notified thresholds" do
    user = user_fixture()
    {fingerprint, _} = put_expiring_key!(user, 20)

    assert :ok = perform_job(GpgExpiryScan, %{})

    assert_enqueued(
      worker: GpgExpiryMail,
      args: %{user_id: user.id, fingerprint: fingerprint, threshold: 30}
    )

    refute_enqueued(worker: GpgExpiryMail, args: %{user_id: user.id, threshold: 7})
  end

  test "delivery records the threshold; repeats and stale reminders no-op" do
    user = user_fixture()
    {fingerprint, _} = put_expiring_key!(user, 5)
    flush_emails()

    args = %{"user_id" => user.id, "fingerprint" => fingerprint, "threshold" => 30}
    assert :ok = perform_job(GpgExpiryMail, args)

    assert_email_sent(fn email ->
      assert email.subject =~ "expires soon"
      assert email.text_body =~ fingerprint
    end)

    assert Repo.get!(User, user.id).gpg_key_expiry_notified_days == [30]

    # Already notified: no second mail.
    assert :ok = perform_job(GpgExpiryMail, args)
    assert_no_email_sent()

    # A replaced key makes the reminder stale.
    other = %{args | "fingerprint" => String.duplicate("C", 40)}
    assert :ok = perform_job(GpgExpiryMail, other)
    assert_no_email_sent()

    # The 7-day threshold is separate.
    assert :ok = perform_job(GpgExpiryMail, %{args | "threshold" => 7})
    assert Enum.sort(Repo.get!(User, user.id).gpg_key_expiry_notified_days) == [7, 30]
  end
end
