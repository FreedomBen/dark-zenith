defmodule DarkZenithWeb.UserLive.Login do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle :if={@registration_enabled}>
              Don't have an account? <.link
                navigate={~p"/users/register"}
                class="font-semibold text-brand hover:underline"
                phx-no-format
              >Sign up</.link> for an account now.
            </:subtitle>
          </.header>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
            required
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>

        <div class="text-center text-sm space-x-2">
          <.link href={~p"/users/reset-password"} class="link">Forgot your password?</.link>
          <span>·</span>
          <.link href={~p"/users/confirm"} class="link">Resend confirmation email</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       registration_enabled: Accounts.registration_enabled?()
     )}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
