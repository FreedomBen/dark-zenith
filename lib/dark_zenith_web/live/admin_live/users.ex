defmodule DarkZenithWeb.AdminAuth do
  @moduledoc """
  Admin-only live_session guard: non-admins get the standard 404 rather
  than an admin-area advertisement.
  """

  def on_mount(:require_admin, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{is_admin: true}} -> {:cont, socket}
      _ -> raise DarkZenithWeb.NotFoundError
    end
  end
end

defmodule DarkZenithWeb.AdminLive.Users do
  @moduledoc """
  Admin user management (DESIGN.md: Admin): list with usage against limits,
  auto-confirmed creation, admin-flag grant/revoke on other users, and
  guarded deletion.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <.header>
          Users
          <:subtitle>
            <DarkZenithWeb.AdminComponents.admin_nav active="users" />
          </:subtitle>
        </.header>

        <section class="border border-base-300 rounded-lg p-4">
          <h2 class="font-semibold mb-2">Create user</h2>
          <p class="text-sm text-base-content/70 mb-2">
            Admin-created accounts are auto-confirmed; no confirmation email is sent.
          </p>
          <.form for={@create_form} id="admin_create_user_form" phx-submit="create_user">
            <div class="flex gap-2 items-end">
              <.input field={@create_form[:email]} type="email" label="Email" required />
              <.input field={@create_form[:password]} type="password" label="Password" required />
              <.button phx-disable-with="Creating..." class="btn btn-primary">Create</.button>
            </div>
          </.form>
        </section>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Email</th>
                <th>Storage</th>
                <th>Repos</th>
                <th>API keys</th>
                <th>Flags</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @users} id={"user-#{row.user.id}"}>
                <td class="font-mono">{row.user.email}</td>
                <td class={over_limit(row.user.storage_bytes, @max_storage) && "text-warning"}>
                  {format_bytes(row.user.storage_bytes)} / {format_bytes(@max_storage)}
                </td>
                <td class={over_limit(row.repository_count, @max_repositories) && "text-warning"}>
                  {row.repository_count} / {@max_repositories}
                </td>
                <td class={over_limit(row.api_key_count, @max_api_keys) && "text-warning"}>
                  {row.api_key_count} / {@max_api_keys}
                </td>
                <td>
                  <span :if={row.user.is_admin} class="badge badge-primary badge-sm">admin</span>
                  <span :if={is_nil(row.user.confirmed_at)} class="badge badge-ghost badge-sm">
                    unconfirmed
                  </span>
                </td>
                <td class="text-right space-x-1">
                  <button
                    :if={row.user.id != @current_scope.user.id and not row.user.is_admin}
                    id={"grant-admin-#{row.user.id}"}
                    class="btn btn-ghost btn-xs"
                    phx-click="set_admin"
                    phx-value-id={row.user.id}
                    phx-value-value="true"
                    data-confirm="Grant admin to this user?"
                  >
                    Grant admin
                  </button>
                  <button
                    :if={row.user.id != @current_scope.user.id and row.user.is_admin}
                    id={"revoke-admin-#{row.user.id}"}
                    class="btn btn-ghost btn-xs"
                    phx-click="set_admin"
                    phx-value-id={row.user.id}
                    phx-value-value="false"
                    data-confirm="Revoke admin from this user?"
                  >
                    Revoke admin
                  </button>
                  <button
                    :if={row.user.id != @current_scope.user.id}
                    id={"delete-user-#{row.user.id}"}
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="delete_user"
                    phx-value-id={row.user.id}
                    data-confirm="Delete this account? Rejected while the user still owns repositories."
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       :max_storage,
       Application.get_env(:dark_zenith, :max_user_storage_bytes, 53_687_091_200)
     )
     |> assign(:max_repositories, Application.get_env(:dark_zenith, :max_user_repositories, 100))
     |> assign(:max_api_keys, Application.get_env(:dark_zenith, :max_user_api_keys, 100))
     |> reload()}
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    case Accounts.admin_create_user(socket.assigns.current_scope.user, params) do
      {:ok, _user} ->
        {:noreply, socket |> reload() |> put_flash(:info, "User created (auto-confirmed).")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: "user"))}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "The user could not be created.")}
    end
  end

  def handle_event("set_admin", %{"id" => id, "value" => value}, socket) do
    case Accounts.set_admin_flag(socket.assigns.current_scope.user, id, value == "true") do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Admin flag updated.")}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, "At least one confirmed admin must remain.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The admin flag could not be changed.")}
    end
  end

  def handle_event("delete_user", %{"id" => id}, socket) do
    case Accounts.admin_delete_user(socket.assigns.current_scope.user, id) do
      {:ok, :ok} ->
        {:noreply, socket |> reload() |> put_flash(:info, "User deleted.")}

      {:error, :owns_repositories} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That user still owns repositories; delete those repositories first."
         )}

      {:error, :last_admin} ->
        {:noreply, put_flash(socket, :error, "At least one confirmed admin must remain.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The user could not be deleted.")}
    end
  end

  defp reload(socket) do
    socket
    |> assign(:users, Accounts.admin_list_users())
    |> assign(:create_form, to_form(%{"email" => "", "password" => ""}, as: "user"))
  end

  defp over_limit(value, limit), do: limit > 0 and value > limit

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
