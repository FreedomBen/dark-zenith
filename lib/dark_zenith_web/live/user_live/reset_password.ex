defmodule DarkZenithWeb.UserLive.ResetPassword do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:narrow}>
      <Layouts.auth_card>
        <div :if={@completed} class="space-y-6" id="reset-complete">
          <div class="text-center">
            <.header>Password reset</.header>
          </div>

          <p class="text-sm">
            Your password was reset and every web and API session was signed out. API keys
            deliberately survive password changes — review them below, since keys created
            during an account compromise stay valid until revoked.
          </p>

          <div :if={@active_keys == []} class="text-sm text-base-content/60">
            You have no active API keys.
          </div>

          <ul :if={@active_keys != []} class="divide-y divide-base-content/10 text-sm">
            <li :for={key <- @active_keys} class="py-2">
              <span class="font-semibold">{key.name}</span>
              <span class="font-mono text-base-content/60 ml-2">{key.key_prefix}…</span>
              <span class="text-xs text-base-content/60 ml-2">{Enum.join(key.scopes, ", ")}</span>
            </li>
          </ul>

          <button
            :if={@active_keys != []}
            id="revoke-all-keys"
            class="btn btn-error w-full"
            phx-click="request_confirm"
            phx-value-event="revoke_all_keys"
          >
            Revoke all API keys
          </button>

          <p class="text-center">
            <.link href={~p"/users/log-in"} class="btn btn-primary w-full">
              Continue to log in
            </.link>
          </p>
        </div>

        <div :if={!@completed}>
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
      </Layouts.auth_card>

      <.confirm_modal pending={@pending_confirm} />
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

    {:ok,
     socket
     |> assign(:completed, false)
     |> assign(:active_keys, [])
     |> assign(:pending_confirm, nil)
     |> assign_form(form_source), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        # The completion page lists active API keys with one-click
        # revocation, because keys deliberately survive password resets
        # (DESIGN.md: Session Tokens).
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully.")
         |> assign(:completed, true)
         |> load_active_keys()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_password(socket.assigns.user, user_params, hash_password: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Revoking every key runs only after the shared modal confirms it
  # (docs/DESIGN_UI.md — Dialogs).
  def handle_event("request_confirm", %{"event" => "revoke_all_keys"}, socket) do
    {:noreply,
     assign(socket, :pending_confirm, %{
       event: "revoke_all_keys",
       params: %{},
       title: "Revoke all API keys",
       message:
         "Every API key on this account stops working immediately; signed download " <>
           "URLs already issued keep working until they expire.",
       confirm_label: "Revoke all keys"
     })}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :pending_confirm, nil)}
  end

  def handle_event("run_confirm", _params, socket) do
    case socket.assigns.pending_confirm do
      %{event: event, params: params} ->
        handle_event(event, params, assign(socket, :pending_confirm, nil))

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke_all_keys", _params, socket) do
    Accounts.revoke_all_api_keys(socket.assigns.user)

    {:noreply,
     socket
     |> put_flash(:info, "All API keys were revoked.")
     |> load_active_keys()}
  end

  defp load_active_keys(socket) do
    active =
      socket.assigns.user
      |> Accounts.list_api_keys()
      |> Enum.reject(&Accounts.ApiKey.expired?/1)

    assign(socket, :active_keys, active)
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
