defmodule DarkZenithWeb.RepositoryLive.Settings do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.Repository

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-xl space-y-10">
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

          <.button phx-disable-with="Saving..." class="btn btn-primary w-full mt-4">
            Save settings
          </.button>
        </.form>

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

      {:ok,
       socket
       |> assign(:repository, repository)
       |> assign_form(changeset)}
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

    case Repositories.update_repository(user, socket.assigns.repository, params) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> assign(:repository, repository)
         |> assign_form(settings_changeset(repository, %{}, socket))
         |> put_flash(:info, "Settings saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "The settings could not be saved.")}
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
end
