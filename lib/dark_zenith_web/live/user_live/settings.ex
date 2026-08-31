defmodule DarkZenithWeb.UserLive.Settings do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.input
          field={@email_form[:current_password]}
          name="current_password"
          id="current_password_for_email"
          type="password"
          label="Current password"
          autocomplete="current-password"
          spellcheck="false"
          value={@email_form_current_password}
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.input
          field={@password_form[:current_password]}
          name="user[current_password]"
          type="password"
          label="Current password"
          id="current_password_for_password"
          autocomplete="current-password"
          spellcheck="false"
          value={@current_password}
          required
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <section class="space-y-4">
        <h2 class="text-lg font-semibold">API keys</h2>

        <div :if={@created_key} class="alert alert-success text-sm" id="created-key">
          <div>
            <p class="font-semibold">Copy your new API key now — it is shown only once:</p>
            <pre class="mt-1 font-mono break-all select-all">{@created_key}</pre>
          </div>
        </div>

        <ul :if={@api_keys != []} class="divide-y divide-base-300 text-sm">
          <li :for={key <- @api_keys} class="py-2 flex items-center justify-between gap-4">
            <div class="min-w-0">
              <span class="font-semibold">{key.name}</span>
              <span class="font-mono text-base-content/60 ml-2">{key.key_prefix}…</span>
              <div class="text-xs text-base-content/60">
                {Enum.join(key.scopes, ", ")}
                <span :if={key.expires_at}>
                  · expires {Calendar.strftime(key.expires_at, "%Y-%m-%d")}
                </span>
                <span
                  :if={DarkZenith.Accounts.ApiKey.expired?(key)}
                  class="badge badge-warning badge-xs align-middle"
                >
                  expired
                </span>
              </div>
            </div>
            <button
              id={"revoke-key-#{key.id}"}
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete_api_key"
              phx-value-id={key.id}
              data-confirm="Revoke this API key? New requests stop immediately, but a signed download URL it already obtained keeps working until that URL expires."
            >
              Revoke
            </button>
          </li>
        </ul>

        <.form for={@key_form} id="create_api_key_form" phx-submit="create_api_key">
          <.input field={@key_form[:name]} type="text" label="Key name" required />
          <fieldset class="fieldset">
            <label
              :for={scope <- ~w(repo:read repo:create repo:update repo:delete package:upload package:delete)}
              class="flex items-center gap-2 text-sm"
            >
              <input type="checkbox" name="api_key[scopes][]" value={scope} class="checkbox checkbox-sm" />
              <span class="font-mono">{scope}</span>
            </label>
          </fieldset>
          <.button phx-disable-with="Creating..." class="btn btn-primary mt-2">
            Create API key
          </.button>
        </.form>
      </section>

      <div class="divider" />

      <section class="space-y-4">
        <h2 class="text-lg font-semibold">GPG signing key</h2>

        <div :if={@gpg} class="space-y-2 text-sm" id="gpg-key-info">
          <p><span class="font-semibold">Fingerprint:</span> <span class="font-mono">{@gpg.fingerprint}</span></p>
          <p>
            <span class="font-semibold">Signing key:</span>
            <span class="font-mono">{@gpg.signing_fingerprint}</span>
          </p>
          <p :if={@gpg.expires_at == nil}><span class="font-semibold">Expires:</span> never</p>
          <p :if={@gpg.expires_at}>
            <span class="font-semibold">Expires:</span>
            {Calendar.strftime(@gpg.expires_at, "%Y-%m-%d")}
          </p>
          <p :if={gpg_expired?(@gpg)} class="alert alert-error" id="gpg-expired">
            This key has expired: signing fails until you replace or remove it.
          </p>
          <p
            :if={not gpg_expired?(@gpg) and gpg_expiring_days(@gpg)}
            class="alert alert-warning"
            id="gpg-expiring"
          >
            This key expires in {gpg_expiring_days(@gpg)} days.
          </p>
          <details>
            <summary class="cursor-pointer">Public key</summary>
            <pre class="bg-base-200 rounded-lg p-3 text-xs overflow-x-auto">{@gpg.public_key}</pre>
          </details>
          <button
            id="remove-gpg-key"
            class="btn btn-error btn-sm"
            phx-click="remove_gpg_key"
            data-confirm="Remove your GPG signing key?"
          >
            Remove key
          </button>
        </div>

        <.form :if={@gpg == nil} for={@gpg_form} id="upload_gpg_key_form" phx-submit="upload_gpg_key">
          <p class="text-sm text-base-content/70 mb-2">
            Upload a dedicated repository-signing key pair. Passphrase-protected keys are
            rejected.
          </p>
          <.input field={@gpg_form[:public_key]} type="textarea" label="ASCII-armored public key" required />
          <.input
            field={@gpg_form[:private_key]}
            type="textarea"
            label="ASCII-armored private key"
            required
          />
          <.button phx-disable-with="Validating..." class="btn btn-primary mt-2">
            Upload key pair
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  defp gpg_expired?(%{expires_at: nil}), do: false

  defp gpg_expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  # The 30/7/1-day warning thresholds used for reminder mail.
  defp gpg_expiring_days(%{expires_at: nil}), do: nil

  defp gpg_expiring_days(%{expires_at: expires_at}) do
    days = DateTime.diff(expires_at, DateTime.utc_now(), :day)
    if days <= 30, do: max(days, 0), else: nil
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:email_form_current_password, nil)
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:current_password, nil)
      |> assign(:trigger_submit, false)
      |> assign(:created_key, nil)
      |> reload_account_sections()

    {:ok, socket}
  end

  defp reload_account_sections(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:api_keys, Accounts.list_api_keys(user))
    |> assign(:key_form, to_form(%{"name" => ""}, as: "api_key"))
    |> assign(:gpg, Accounts.get_gpg_key_info(user))
    |> assign(:gpg_form, to_form(%{"public_key" => "", "private_key" => ""}, as: "gpg"))
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Accounts.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       password_form: password_form,
       current_password: user_params["current_password"]
     )}
  end

  def handle_event("create_api_key", %{"api_key" => params}, socket) do
    user = socket.assigns.current_scope.user
    attrs = %{name: params["name"], scopes: params["scopes"] || []}

    case Accounts.create_api_key(user, attrs) do
      {:ok, {plaintext, api_key}} ->
        DarkZenith.Audit.record!("api_key.create",
          actor: user,
          target: {:api_key, api_key.id},
          metadata: %{"name" => api_key.name, "scopes" => api_key.scopes}
        )

        {:noreply,
         socket
         |> assign(:created_key, plaintext)
         |> reload_account_sections()
         |> put_flash(:info, "API key created.")}

      {:error, :quota_exceeded} ->
        {:noreply, put_flash(socket, :error, "You have reached your API key limit.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :key_form, to_form(changeset, as: "api_key"))}
    end
  end

  def handle_event("delete_api_key", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.delete_api_key(user, id) do
      :ok ->
        DarkZenith.Audit.record!("api_key.revoke",
          actor: user,
          target: {:api_key, id},
          metadata: %{}
        )

        {:noreply,
         socket |> reload_account_sections() |> put_flash(:info, "API key revoked.")}

      :error ->
        {:noreply, put_flash(socket, :error, "That API key could not be revoked.")}
    end
  end

  def handle_event("upload_gpg_key", %{"gpg" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.upsert_gpg_key(user, params["public_key"] || "", params["private_key"] || "") do
      {:ok, _user} ->
        {:noreply,
         socket |> reload_account_sections() |> put_flash(:info, "GPG key uploaded.")}

      {:error, :validation_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That key pair was rejected: it must be a matching, passphrase-free V4 signing key " <>
             "with an allowed algorithm and at least 30 days before expiry."
         )}

      {:error, :replacement_not_implemented} ->
        {:noreply,
         put_flash(socket, :error, "Key replacement is not available yet; remove the key first.")}

      {:error, _infra} ->
        {:noreply, put_flash(socket, :error, "Key validation infrastructure is unavailable.")}
    end
  end

  def handle_event("remove_gpg_key", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.remove_gpg_key(user) do
      :ok ->
        {:noreply, socket |> reload_account_sections() |> put_flash(:info, "GPG key removed.")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The key is still used by your repositories: clear metadata signing on them first."
         )}

      {:error, :not_found} ->
        {:noreply, reload_account_sections(socket)}
    end
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> DarkZenith.Accounts.User.validate_current_password(user_params["current_password"])

    case changeset do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
