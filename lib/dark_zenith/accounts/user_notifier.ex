defmodule DarkZenith.Accounts.UserNotifier do
  alias DarkZenith.Mail

  # Enqueues the email for Oban-backed delivery in the caller's transaction
  # (DESIGN.md: Email Delivery).
  defp deliver(recipient, subject, body) do
    {:ok, recipient |> Mail.build(subject, body) |> Mail.enqueue()}
  end

  @doc """
  Security notification for a changed or reset password (Session Tokens:
  API keys survive, so recovery must surface them).
  """
  def deliver_password_changed(user) do
    deliver(user.email, "Your password was changed", """

    ==============================

    Hi #{user.email},

    The password for your Dark Zenith account was just changed. Web sessions
    and API session tokens were signed out; API keys remain valid and can be
    reviewed in your account settings.

    If you did not make this change, reset your password immediately and
    revoke your API keys.

    ==============================
    """)
  end

  @doc "Security notification to the previous address after an email change."
  def deliver_email_changed(previous_email, new_email) do
    deliver(previous_email, "Your account email was changed", """

    ==============================

    Hi #{previous_email},

    The email address for your Dark Zenith account was changed to
    #{new_email}.

    If you did not make this change, contact your administrator immediately.

    ==============================
    """)
  end

  @doc "Security notification for a newly created API key."
  def deliver_api_key_created(user, key_name) do
    deliver(user.email, "A new API key was created", """

    ==============================

    Hi #{user.email},

    A new API key named "#{key_name}" was just created for your Dark Zenith
    account.

    If you did not create it, revoke it in your account settings and change
    your password.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to confirm the account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end
end
