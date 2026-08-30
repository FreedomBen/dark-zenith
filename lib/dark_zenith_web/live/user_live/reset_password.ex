defmodule DarkZenithWeb.UserLive.ResetPassword do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Reset password</.header>
        </div>

        <.form
          for={@form}
          id="reset_password_form"
          phx-submit="reset_password"
          phx-change="validate"
        >
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.button phx-disable-with="Resetting..." class="btn btn-primary w-full">
            Reset password
          </.button>
        </.form>

        <p class="text-center mt-4 space-x-2">
          <.link href={~p"/users/log-in"} class="link">Log in</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket = assign_user_and_token(socket, params)

    form_source =
      case socket.assigns do
        %{user: user} -> Accounts.change_user_password(user, %{}, hash_password: false)
        _ -> %{}
      end

    {:ok, assign_form(socket, form_source), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_password(socket.assigns.user, user_params, hash_password: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_user_and_token(socket, %{"token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      assign(socket, user: user, token: token)
    else
      socket
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, %{} = source) do
    assign(socket, :form, to_form(source, as: "user"))
  end
end
