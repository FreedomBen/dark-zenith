defmodule DarkZenithWeb.UserLive.ConfirmationInstructions do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:narrow}>
      <Layouts.auth_card>
        <div class="text-center">
          <.header>
            No confirmation instructions received?
            <:subtitle>We'll send a new confirmation link to your inbox</:subtitle>
          </.header>
        </div>

        <.form for={@form} id="resend_confirmation_form" phx-submit="send_instructions">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button phx-disable-with="Sending..." class="btn btn-primary w-full">
            Resend confirmation instructions
          </.button>
        </.form>

        <p class="text-center mt-4 space-x-2">
          <.link href={~p"/users/log-in"} class="link">Log in</.link>
        </p>
      </Layouts.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_confirmation_instructions(
        user,
        &url(~p"/users/confirm/#{&1}")
      )
    end

    info =
      "If your email is in our system and it has not been confirmed yet, " <>
        "you will receive an email with instructions shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
