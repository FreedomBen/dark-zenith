defmodule DarkZenithWeb.RepositoryLive.New do
  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.Repository

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-xl">
        <.header>
          Create Repository
          <:subtitle>The slug becomes the repository URL and cannot be changed later</:subtitle>
        </.header>

        <.form for={@form} id="repository_form" phx-submit="save" phx-change="validate">
          <.input field={@form[:name]} type="text" label="Name" required />
          <.input
            field={@form[:slug]}
            type="text"
            label="Slug"
            placeholder="my-repo"
            required
          />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <.input field={@form[:is_public]} type="checkbox" label="Public repository" />

          <.button phx-disable-with="Creating..." class="btn btn-primary w-full mt-4">
            Create repository
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Repository.create_changeset(%Repository{}, %{}, current_user(socket))
    {:ok, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("validate", %{"repository" => params}, socket) do
    changeset = Repository.create_changeset(%Repository{}, params, current_user(socket))
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"repository" => params}, socket) do
    case Repositories.create_repository(current_user(socket), params) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository created.")
         |> push_navigate(to: ~p"/repos/#{repository.slug}")}

      {:error, :quota_exceeded} ->
        {:noreply,
         put_flash(socket, :error, "Creating this repository would exceed your repository limit.")}

      {:error, :signing_unavailable} ->
        {:noreply, put_flash(socket, :error, "Metadata signing is temporarily unavailable.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp current_user(socket), do: socket.assigns.current_scope.user

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "repository"))
  end
end
