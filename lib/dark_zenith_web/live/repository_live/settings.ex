defmodule DarkZenithWeb.RepositoryLive.Settings do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Collaborators
  alias DarkZenith.Collaborators.{Collaborator, Invitation}
  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.Repository

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:prose}>
      <div class="space-y-10">
        <.header>
          Repository Settings
          <:subtitle>{@repository.slug} — the slug is immutable</:subtitle>
        </.header>

        <.form
          for={@form}
          id="repository_settings_form"
          phx-submit="save"
          phx-change="validate"
        >
          <.input field={@form[:name]} type="text" label="Name" required />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <.input field={@form[:is_public]} type="checkbox" label="Public repository" />

          <div :if={@owner_fingerprint} class="mt-4 space-y-2 border-t border-base-300 pt-4">
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="repository[metadata_signing]"
                value="true"
                checked={@repository.gpg_key_fingerprint != nil}
                class="checkbox checkbox-sm"
              /> Sign repository metadata (repomd.xml.asc) with your GPG key
            </label>

            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="repository[sign_rpms]"
                value="true"
                checked={@repository.sign_rpms}
                class="checkbox checkbox-sm"
              /> Automatically sign uploaded RPMs
            </label>

            <label
              :if={!@repository.sign_rpms and @repository.package_count > 0}
              class="flex items-center gap-2 text-sm pl-6 text-base-content/80"
            >
              <input
                type="checkbox"
                name="repository[existing_package_strategy]"
                value="resign"
                class="checkbox checkbox-sm"
              /> Re-sign all {@repository.package_count} existing packages (required to enable
              RPM signing on a non-empty repository)
            </label>
          </div>

          <p :if={!@owner_fingerprint} class="mt-4 text-sm text-base-content/60">
            Upload a GPG key in your account settings to enable signing.
          </p>

          <.button phx-disable-with="Saving..." class="btn btn-primary w-full mt-4">
            Save settings
          </.button>
        </.form>

        <section
          :if={@repository.rpm_signing_state == "signing" and @signing_progress}
          class="border border-warning/40 rounded-lg p-4 text-sm space-y-2"
          id="signing-progress"
        >
          <h2 class="font-semibold">Re-signing in progress</h2>
          <p>
            {@signing_progress.counts["succeeded"]} signed · {@signing_progress.counts["pending"] +
              @signing_progress.counts["executing"]} pending · {@signing_progress.counts["failed"]} failed
          </p>
          <p class="text-base-content/70">
            RPM signature verification stays off (gpgcheck=0) until every package is signed.
          </p>
          <div :if={@signing_progress.failed?} class="alert alert-error">
            <span>
              The transition failed ({@signing_progress.error_code}). An admin can reset the
              failed items from the background-jobs view, or delete the affected packages to
              cancel their items.
            </span>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold mb-2">Manage Collaborators</h2>
          <p class="text-sm text-base-content/70 mb-4">
            Collaborators get read access to this repository while it is private. Removing a
            collaborator stops new private downloads immediately, but download URLs already
            issued to them keep working for their remaining signed lifetime.
          </p>

          <.form
            :if={!@repository.is_public}
            for={@collaborator_form}
            id="add_collaborator_form"
            phx-submit="add_collaborator"
          >
            <div class="flex items-end gap-2">
              <div class="grow">
                <.input
                  field={@collaborator_form[:email]}
                  type="email"
                  label="Add by email"
                  placeholder="user@example.com"
                />
              </div>
              <.button phx-disable-with="Adding..." class="btn btn-primary">Add</.button>
            </div>
          </.form>

          <p :if={@repository.is_public} class="text-sm italic">
            Make the repository private to add collaborators. Existing entries below are
            dormant while the repository is public.
          </p>

          <ul :if={@collaborator_rows != []} class="mt-4 divide-y divide-base-300">
            <li
              :for={row <- @collaborator_rows}
              class="py-2 flex items-center justify-between gap-4"
            >
              <div class="min-w-0">
                <span class="font-mono text-sm break-all">{row_email(row)}</span>
                <div class="text-xs text-base-content/60 space-x-2">
                  <span class="badge badge-ghost badge-sm">{row_type(row)}</span>
                  <span title={notification_hint(row)}>
                    notification: {row.notification_status}
                  </span>
                  <span :if={match?(%Invitation{}, row)}>
                    {invitation_expiry_label(row)}
                  </span>
                </div>
              </div>
              <button
                :if={match?(%Collaborator{}, row)}
                id={"remove-collaborator-#{row.id}"}
                class="btn btn-ghost btn-sm text-error"
                phx-click="remove_collaborator"
                phx-value-id={row.id}
                data-confirm="Remove this collaborator? New private downloads stop immediately, but any download URL already issued to them keeps working for its remaining signed lifetime."
              >
                Remove
              </button>
              <button
                :if={match?(%Invitation{}, row)}
                id={"cancel-invitation-#{row.id}"}
                class="btn btn-ghost btn-sm text-error"
                phx-click="cancel_invitation"
                phx-value-id={row.id}
                data-confirm="Cancel this pending invitation?"
              >
                Cancel
              </button>
            </li>
          </ul>

          <p :if={@collaborator_rows == []} class="mt-4 text-sm text-base-content/60">
            No collaborators or pending invitations.
          </p>
        </section>

        <section class="border border-error/40 rounded-lg p-4">
          <h2 class="font-semibold text-error mb-2">Danger zone</h2>
          <p class="text-sm mb-4">
            Deleting a repository permanently removes its packages and metadata. Its slug is
            retired and cannot be reused by other users.
          </p>
          <button
            id="delete_repository"
            class="btn btn-error"
            phx-click="delete"
            data-confirm="Permanently delete this repository? This cannot be undone."
          >
            Delete repository
          </button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    repository = Repositories.get_repository_by_slug(slug)
    user = socket.assigns.current_scope.user

    if repository && DarkZenith.Authorization.can_manage?(user, repository) do
      changeset = settings_changeset(repository, %{}, socket)

      owner =
        if user.id == repository.user_id,
          do: user,
          else: DarkZenith.Accounts.get_user!(repository.user_id)

      {:ok,
       socket
       |> assign(:repository, repository)
       |> assign(:owner_fingerprint, owner.gpg_key_fingerprint)
       |> assign_signing_progress(repository)
       |> assign_form(changeset)
       |> assign(:collaborator_rows, Collaborators.list_rows(repository))
       |> assign_collaborator_form()}
    else
      raise DarkZenithWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("validate", %{"repository" => params}, socket) do
    changeset = settings_changeset(socket.assigns.repository, params, socket)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"repository" => params}, socket) do
    user = socket.assigns.current_scope.user
    params = translate_signing_params(params, socket)

    case Repositories.update_repository(user, socket.assigns.repository, params) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> assign(:repository, repository)
         |> assign_signing_progress(repository)
         |> assign_form(settings_changeset(repository, %{}, socket))
         |> put_flash(:info, "Settings saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :conflict_gpg_key_transition_in_progress} ->
        {:noreply, put_flash(socket, :error, "A signing transition is already running.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "The settings could not be saved.")}
    end
  end

  def handle_event("add_collaborator", %{"collaborator" => %{"email" => email}}, socket) do
    user = socket.assigns.current_scope.user

    case Collaborators.add_collaborator(user, socket.assigns.repository, email) do
      {:ok, :created, %Invitation{notification_status: "suppressed"}} ->
        {:noreply,
         socket
         |> refresh_collaborators()
         |> put_flash(
           :info,
           "Invitation recorded. An admin must create the account before it can be accepted."
         )}

      {:ok, :created, %Invitation{}} ->
        {:noreply, socket |> refresh_collaborators() |> put_flash(:info, "Invitation sent.")}

      {:ok, :created, %Collaborator{}} ->
        {:noreply, socket |> refresh_collaborators() |> put_flash(:info, "Collaborator added.")}

      {:ok, :existing, _row} ->
        {:noreply,
         socket
         |> refresh_collaborators()
         |> put_flash(:info, "That email was already added — showing the existing entry.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :collaborator_form, to_form(changeset, as: "collaborator"))}

      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(socket, :error, "This repository has reached its collaborator limit.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "The collaborator could not be added.")}
    end
  end

  def handle_event("remove_collaborator", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Collaborators.remove_collaborator(user, socket.assigns.repository, id) do
      :ok ->
        {:noreply, socket |> refresh_collaborators() |> put_flash(:info, "Collaborator removed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The collaborator could not be removed.")}
    end
  end

  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Collaborators.cancel_invitation(user, socket.assigns.repository, id) do
      :ok ->
        {:noreply, socket |> refresh_collaborators() |> put_flash(:info, "Invitation canceled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The invitation could not be canceled.")}
    end
  end

  def handle_event("delete", _params, socket) do
    user = socket.assigns.current_scope.user

    case Repositories.delete_repository(user, socket.assigns.repository) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository deleted.")
         |> push_navigate(to: ~p"/repos")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The repository could not be deleted.")}
    end
  end

  # Checkbox semantics: an unchecked signing box is absent from the params.
  # metadata_signing maps to the owner's fingerprint or nil; sign_rpms
  # defaults to false when unchecked and only a checked resign box carries
  # the strategy.
  defp translate_signing_params(params, socket) do
    if socket.assigns.owner_fingerprint do
      metadata? = Map.get(params, "metadata_signing") == "true"
      sign_rpms? = Map.get(params, "sign_rpms") == "true"

      params
      |> Map.delete("metadata_signing")
      |> Map.put("gpg_key_fingerprint", if(metadata?, do: socket.assigns.owner_fingerprint))
      |> Map.put("sign_rpms", sign_rpms?)
    else
      params
    end
  end

  defp assign_signing_progress(socket, repository) do
    progress =
      if repository.rpm_signing_state == "signing" and repository.signing_transition_id do
        transition =
          DarkZenith.SigningTransitions.get_transition(repository.signing_transition_id)

        transition &&
          %{
            counts: DarkZenith.SigningTransitions.item_counts(transition.id),
            failed?: transition.status == "failed",
            error_code: transition.last_error_code
          }
      end

    assign(socket, :signing_progress, progress)
  end

  defp settings_changeset(repository, params, socket) do
    owner =
      if socket.assigns.current_scope.user.id == repository.user_id do
        socket.assigns.current_scope.user
      else
        DarkZenith.Accounts.get_user!(repository.user_id)
      end

    Repository.update_changeset(repository, params, owner)
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "repository"))
  end

  defp assign_collaborator_form(socket) do
    assign(socket, :collaborator_form, to_form(%{"email" => ""}, as: "collaborator"))
  end

  defp refresh_collaborators(socket) do
    socket
    |> assign(:collaborator_rows, Collaborators.list_rows(socket.assigns.repository))
    |> assign_collaborator_form()
  end

  defp row_email(%Collaborator{} = row), do: row.user.email
  defp row_email(%Invitation{} = row), do: row.email

  defp row_type(%Collaborator{}), do: "collaborator"
  defp row_type(%Invitation{}), do: "invitation"

  defp notification_hint(%Invitation{notification_status: "suppressed"}) do
    "No email was sent because registration is disabled; an admin must create the account."
  end

  defp notification_hint(_row), do: nil

  defp invitation_expiry_label(%Invitation{expires_at: nil}), do: "Never expires"

  defp invitation_expiry_label(%Invitation{expires_at: expires_at}) do
    "Expires #{Calendar.strftime(expires_at, "%Y-%m-%d")}"
  end
end
