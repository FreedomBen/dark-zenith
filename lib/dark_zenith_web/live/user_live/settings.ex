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
              :for={
                scope <-
                  ~w(repo:read repo:create repo:update repo:delete package:upload package:delete)
              }
              class="flex items-center gap-2 text-sm"
            >
              <input
                type="checkbox"
                name="api_key[scopes][]"
                value={scope}
                class="checkbox checkbox-sm"
              />
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

        <div
          :if={@generated_gpg_private_key}
          class="alert alert-warning block space-y-2"
          id="generated-gpg-private-key"
        >
          <p class="font-semibold">
            Your generated private key — copy or download it now.
          </p>
          <p class="text-xs">
            Dark Zenith keeps an encrypted copy for signing, but the key will
            never be shown again. Store this backup somewhere safe.
          </p>
          <pre class="bg-base-200 rounded-lg p-3 text-xs overflow-x-auto select-all">{@generated_gpg_private_key}</pre>
          <a
            class="btn btn-sm"
            href={"data:application/pgp-keys;base64," <> Base.encode64(@generated_gpg_private_key)}
            download="dark-zenith-signing-key.asc"
          >
            Download private key
          </a>
        </div>

        <div :if={@gpg} class="space-y-2 text-sm" id="gpg-key-info">
          <p>
            <span class="font-semibold">Fingerprint:</span>
            <span class="font-mono">{@gpg.fingerprint}</span>
          </p>
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

          <div :if={@gpg.transition} class="alert alert-info block space-y-1" id="gpg-transition">
            <p class="font-semibold">{transition_title(@gpg.transition)}</p>
            <p class="text-xs">
              Status: {@gpg.transition.status}
              <span :if={@gpg.transition.resume_status}>
                (resumes {@gpg.transition.resume_status})
              </span>
              · Repositories updated: {@gpg_progress.repos_done}/{@gpg_progress.repos_total} · Packages processed: {@gpg_progress.items_done}/{@gpg_progress.items_total}
            </p>
            <p :if={@gpg.replacement_in_progress and @gpg.previous_public_key} class="text-xs">
              Both the previous and new public keys are served until re-signing completes.
            </p>
            <p
              :if={@gpg.transition.status == "failed"}
              class="text-error text-xs"
              id="gpg-transition-failed"
            >
              Failed with {@gpg.transition.last_error_code}. An administrator can reset the
              transition from the admin signing-transitions view.
            </p>
          </div>

          <div
            :if={@gpg.transition == nil and gpg_in_use?(@gpg_usage)}
            class="space-y-2"
            id="gpg-removal-strategies"
          >
            <p class="text-sm">
              This key is used by {@gpg_usage.metadata_signed} metadata-signed and {@gpg_usage.rpm_signed} RPM-signed repositories. Removing it requires an
              explicit strategy (or upload a replacement key pair below):
            </p>
            <button
              :if={@gpg_usage.rpm_signed == 0}
              id="revoke-clear-metadata"
              class="btn btn-warning btn-sm"
              phx-click="revoke_clear_metadata"
              data-confirm="Clear metadata signing on all your repositories and remove the key?"
            >
              Clear metadata signing everywhere
            </button>
            <button
              id="revoke-delete-packages"
              class="btn btn-error btn-sm"
              phx-click="revoke_delete_packages"
              data-confirm="Delete every package in your RPM-signed repositories, disable signing, and remove the key? This cannot be undone."
            >
              Delete signed packages and remove the key
            </button>
          </div>

          <button
            :if={@gpg.transition == nil and not gpg_in_use?(@gpg_usage)}
            id="remove-gpg-key"
            class="btn btn-error btn-sm"
            phx-click="remove_gpg_key"
            data-confirm="Remove your GPG signing key?"
          >
            Remove key
          </button>
        </div>

        <.form
          :if={@gpg == nil or @gpg.transition == nil}
          for={@gpg_form}
          id="upload_gpg_key_form"
          phx-submit="upload_gpg_key"
        >
          <p class="text-sm text-base-content/70 mb-2">
            {if @gpg,
              do:
                "Upload a new key pair to start a durable key replacement: " <>
                  "affected repositories and packages are re-signed in the background.",
              else: "Upload a dedicated repository-signing key pair."} Passphrase-protected
            keys are rejected.
          </p>
          <.input
            field={@gpg_form[:public_key]}
            type="textarea"
            label="ASCII-armored public key"
            required
          />
          <.input
            field={@gpg_form[:private_key]}
            type="textarea"
            label="ASCII-armored private key"
            required
          />
          <.button phx-disable-with="Validating..." class="btn btn-primary mt-2">
            {if @gpg, do: "Replace key pair", else: "Upload key pair"}
          </.button>
        </.form>

        <.form
          :if={@gpg == nil or @gpg.transition == nil}
          for={@gpg_generation_form}
          id="generate_gpg_key_form"
          phx-submit="generate_gpg_key"
        >
          <p class="text-sm text-base-content/70 mb-2">
            {if @gpg,
              do: "Or have Dark Zenith generate the replacement key pair for you.",
              else: "Or have Dark Zenith generate a key pair for you."} The private key is
            shown exactly once so you can keep an offline backup.
          </p>
          <.input
            field={@gpg_generation_form[:algorithm]}
            type="select"
            label="Algorithm"
            options={[
              {"Ed25519 (recommended)", "ed25519"},
              {"RSA-4096", "rsa4096"},
              {"RSA-3072", "rsa3072"},
              {"ECDSA P-256", "nistp256"},
              {"ECDSA P-384", "nistp384"}
            ]}
          />
          <.button phx-disable-with="Generating..." class="btn btn-secondary mt-2">
            Generate key pair
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
      |> assign(:generated_gpg_private_key, nil)
      |> reload_account_sections()

    {:ok, socket}
  end

  defp reload_account_sections(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:api_keys, Accounts.list_api_keys(user))
    |> assign(:key_form, to_form(%{"name" => ""}, as: "api_key"))
    |> assign_gpg_sections(user)
    |> assign(:gpg_form, to_form(%{"public_key" => "", "private_key" => ""}, as: "gpg"))
    |> assign(:gpg_generation_form, to_form(%{"algorithm" => "ed25519"}, as: "gpg_generation"))
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

        {:noreply, socket |> reload_account_sections() |> put_flash(:info, "API key revoked.")}

      :error ->
        {:noreply, put_flash(socket, :error, "That API key could not be revoked.")}
    end
  end

  def handle_event("upload_gpg_key", %{"gpg" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.upsert_gpg_key(user, params["public_key"] || "", params["private_key"] || "") do
      {:ok, _user} ->
        {:noreply, socket |> reload_account_sections() |> put_flash(:info, "GPG key uploaded.")}

      {:accepted, _transition} ->
        {:noreply,
         socket
         |> reload_account_sections()
         |> put_flash(
           :info,
           "Key replacement started: repositories and packages are being re-signed."
         )}

      {:error, :transition_in_progress} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Another key transition is unresolved (or a repository is mid re-sign); " <>
             "wait for it to finish."
         )}

      {:error, :validation_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That key pair was rejected: it must be a matching, passphrase-free V4 signing key " <>
             "with an allowed algorithm and at least 30 days before expiry."
         )}

      {:error, _infra} ->
        {:noreply, put_flash(socket, :error, "Key validation infrastructure is unavailable.")}
    end
  end

  def handle_event("generate_gpg_key", params, socket) do
    user = socket.assigns.current_scope.user
    algorithm = get_in(params, ["gpg_generation", "algorithm"]) || "ed25519"

    case Accounts.generate_gpg_key(user, algorithm) do
      {:ok, _user, private_armored} ->
        {:noreply,
         socket
         |> reload_account_sections()
         |> assign(:generated_gpg_private_key, private_armored)
         |> put_flash(:info, "GPG key generated. Save the private key now: it is shown once.")}

      {:accepted, _transition, private_armored} ->
        {:noreply,
         socket
         |> reload_account_sections()
         |> assign(:generated_gpg_private_key, private_armored)
         |> put_flash(
           :info,
           "Key replacement started with your generated key: repositories and packages " <>
             "are being re-signed. Save the private key now: it is shown once."
         )}

      {:error, :transition_in_progress} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Another key transition is unresolved (or a repository is mid re-sign); " <>
             "wait for it to finish."
         )}

      {:error, :validation_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Key generation was rejected: the chosen algorithm is not supported by this server."
         )}

      {:error, _infra} ->
        {:noreply, put_flash(socket, :error, "Key generation infrastructure is unavailable.")}
    end
  end

  def handle_event("remove_gpg_key", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.remove_gpg_key(user) do
      :ok ->
        {:noreply, socket |> reload_account_sections() |> put_flash(:info, "GPG key removed.")}

      {:error, {:in_use, _counts}} ->
        {:noreply,
         socket
         |> reload_account_sections()
         |> put_flash(
           :error,
           "The key is still used by your repositories: choose a removal strategy."
         )}

      {:error, :transition_in_progress} ->
        {:noreply,
         put_flash(socket, :error, "A key transition is already removing or replacing this key.")}

      {:error, :not_found} ->
        {:noreply, reload_account_sections(socket)}
    end
  end

  def handle_event("revoke_clear_metadata", _params, socket) do
    start_removal(socket, "clear_metadata_signing")
  end

  def handle_event("revoke_delete_packages", _params, socket) do
    start_removal(socket, "delete_signed_packages")
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

  defp start_removal(socket, strategy) do
    user = socket.assigns.current_scope.user

    case DarkZenith.SigningTransitions.UserWide.start_removal(user, strategy) do
      {:accepted, _transition} ->
        {:noreply,
         socket
         |> reload_account_sections()
         |> put_flash(:info, "Key removal started: repositories are being updated.")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Clearing metadata signing requires disabling RPM signing everywhere first."
         )}

      {:error, :transition_in_progress} ->
        {:noreply, put_flash(socket, :error, "Another key transition is already unresolved.")}

      {:error, :not_found} ->
        {:noreply, reload_account_sections(socket)}
    end
  end

  defp assign_gpg_sections(socket, user) do
    gpg = Accounts.get_gpg_key_info(user)

    usage =
      if gpg,
        do: DarkZenith.SigningTransitions.UserWide.affected_repository_counts(user.id)

    progress =
      if gpg && gpg.transition do
        repos = DarkZenith.SigningTransitions.repository_counts(gpg.transition.id)
        items = DarkZenith.SigningTransitions.item_counts(gpg.transition.id)

        %{
          repos_done: repos["applied"] + repos["satisfied_deleted"],
          repos_total: repos |> Map.values() |> Enum.sum(),
          items_done: items["succeeded"] + items["canceled"],
          items_total: items |> Map.values() |> Enum.sum()
        }
      end

    socket
    |> assign(:gpg, gpg)
    |> assign(:gpg_usage, usage)
    |> assign(:gpg_progress, progress)
  end

  defp gpg_in_use?(nil), do: false
  defp gpg_in_use?(usage), do: usage.metadata_signed > 0 or usage.rpm_signed > 0

  defp transition_title(%{kind: "replace_gpg_key"}), do: "Key replacement in progress"

  defp transition_title(%{kind: "clear_metadata_signing"}),
    do: "Metadata signing removal in progress"

  defp transition_title(%{kind: "delete_signed_packages"}),
    do: "Signed-package deletion in progress"

  defp transition_title(_), do: "Key transition in progress"
end
