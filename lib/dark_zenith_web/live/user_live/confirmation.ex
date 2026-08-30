defmodule DarkZenithWeb.UserLive.Confirmation do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Confirm account</.header>
        </div>

        <.form for={@form} id="confirmation_form" phx-submit="confirm_account">
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button phx-disable-with="Confirming..." class="btn btn-primary w-full">
            Confirm my account
          </.button>
        </.form>

        <p class="text-center mt-4">
          <.link href={~p"/users/log-in"} class="link">Log in</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    form = to_form(%{"token" => token}, as: "user")
    {:ok, assign(socket, form: form), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after confirmation to avoid a
  # leaked token giving the user access to the account.
  @impl true
  def handle_event("confirm_account", %{"user" => %{"token" => token}}, socket) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User confirmed successfully.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, :invalid_token} ->
        # If there is a current user and the account was already confirmed,
        # then odds are that the confirmation link was already visited, either
        # by some automation or by the user themselves, so we redirect without
        # a warning message.
        case socket.assigns do
          %{current_scope: %{user: %{confirmed_at: confirmed_at}}}
          when not is_nil(confirmed_at) ->
            {:noreply, redirect(socket, to: ~p"/")}

          %{} ->
            {:noreply,
             socket
             |> put_flash(:error, "User confirmation link is invalid or it has expired.")
             |> redirect(to: ~p"/")}
        end
    end
  end
end
