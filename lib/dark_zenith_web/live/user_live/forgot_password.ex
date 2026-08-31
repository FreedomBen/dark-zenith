defmodule DarkZenithWeb.UserLive.ForgotPassword do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:narrow}>
      <Layouts.auth_card>
        <div class="text-center">
          <.header>
            Forgot your password?
            <:subtitle>We'll send a password reset link to your inbox</:subtitle>
          </.header>
        </div>

        <.form for={@form} id="reset_password_form" phx-submit="send_email">
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
            Send password reset instructions
          </.button>
        </.form>

        <p class="text-center mt-4">
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
  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions to " <>
        "reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
