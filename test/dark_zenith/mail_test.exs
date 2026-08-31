defmodule DarkZenith.MailTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import Swoosh.TestAssertions

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenith.Mail
  alias DarkZenith.Workers.EmailDelivery

  describe "adapter_for/1" do
    test "maps the documented aliases" do
      assert Mail.adapter_for("zepto") == Swoosh.Adapters.ZeptoMail
      assert Mail.adapter_for("smtp") == Swoosh.Adapters.SMTP
      assert Mail.adapter_for("local") == Swoosh.Adapters.Local
    end

    test "unknown aliases refuse boot" do
      assert_raise ArgumentError, ~r/unknown MAIL_ADAPTER/, fn ->
        Mail.adapter_for("sendmail")
      end
    end
  end

  describe "enqueue/1 and EmailDelivery" do
    test "enqueued mail is delivered by the worker with the configured sender" do
      Mail.enqueue(Mail.build("someone@example.com", "Hello", "Body text"))

      assert [job] = all_enqueued(worker: EmailDelivery)
      assert job.args["to"] == "someone@example.com"
      assert job.args["subject"] == "Hello"

      assert :ok = perform_job(EmailDelivery, job.args)

      assert_email_sent(fn email ->
        assert email.to == [{"", "someone@example.com"}]
        assert email.subject == "Hello"
        assert email.text_body == "Body text"
        assert email.from == Mail.from()
      end)
    end

    test "the worker follows the Background Retry Policy backoff" do
      for {attempt, expected} <- [{1, 30}, {2, 60}, {8, 3600}, {20, 3600}] do
        assert EmailDelivery.backoff(%Oban.Job{attempt: attempt}) == expected
      end
    end
  end

  describe "security notifications" do
    test "password change enqueues mail and audits in the same operation" do
      user = user_fixture()

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "brand new password!"
        })

      assert [job] =
               all_enqueued(
                 worker: EmailDelivery,
                 args: %{to: user.email, subject: "Your password was changed"}
               )

      assert job.args["subject"] =~ "password"
      assert Enum.any?(Audit.list_events(), &(&1.action == "auth.password_change"))
    end

    test "password reset notifies and audits" do
      user = user_fixture()
      {:ok, _} = Accounts.reset_user_password(user, %{password: "another new password!"})

      assert [job] =
               all_enqueued(
                 worker: EmailDelivery,
                 args: %{to: user.email, subject: "Your password was changed"}
               )

      assert job.args["subject"] =~ "password"
      assert Enum.any?(Audit.list_events(), &(&1.action == "auth.password_reset"))
    end

    test "a confirmed email change notifies the previous address" do
      user = user_fixture()
      previous = user.email
      new_email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: new_email}, user.email, url)
        end)

      {:ok, _} = Accounts.update_user_email(user, token)

      assert [job] = all_enqueued(worker: EmailDelivery, args: %{to: previous, subject: "Your account email was changed"})
      assert job.args["text_body"] =~ new_email
    end

    test "API key creation notifies the owner" do
      user = user_fixture()
      {:ok, _} = Accounts.create_api_key(user, %{name: "ci-key", scopes: ["repo:read"]})

      assert [job] =
               all_enqueued(worker: EmailDelivery, args: %{subject: "A new API key was created"})

      assert job.args["text_body"] =~ "ci-key"
    end

    test "gen.auth instruction mail is queued rather than sent inline" do
      user = unconfirmed_user_fixture()

      {:ok, email} =
        Accounts.deliver_user_confirmation_instructions(user, &"http://x/confirm/#{&1}")

      assert email.text_body =~ "http://x/confirm/"
      assert_enqueued(worker: EmailDelivery, args: %{to: user.email})
    end
  end
end
