defmodule DarkZenith.Collaborators.Notifier do
  @moduledoc """
  Collaborator and invitation notification mail (DESIGN.md: Repository
  Collaborators): registered users get a direct link to the repository;
  unregistered invitees get a registration link that converts the pending
  invitation on signup.
  """

  import Swoosh.Email

  alias DarkZenith.Mail
  alias DarkZenith.Mailer

  @doc "Direct repository-link notification for a registered collaborator."
  def deliver_collaborator_added(email, repository) do
    deliver(email, "You now have access to #{repository.name}", """

    ==============================

    Hi #{email},

    You have been granted access to the repository "#{repository.name}".

    #{DarkZenithWeb.Endpoint.url()}/repos/#{repository.slug}

    ==============================
    """)
  end

  @doc "Registration-link invitation for an unregistered email address."
  def deliver_invitation(email, repository) do
    deliver(email, "You've been invited to #{repository.name}", """

    ==============================

    Hi #{email},

    You have been invited to access the repository "#{repository.name}".
    Create an account with this email address to accept the invitation:

    #{DarkZenithWeb.Endpoint.url()}/users/register

    ==============================
    """)
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mail.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
