defmodule DarkZenithWeb.RepositoryLive.Upload do
  @moduledoc """
  Upload RPM (`GET /repos/:slug/upload`) — direct-to-B2 transfer with
  preview and confirm (DESIGN.md: Web Interface — Upload RPM).

  The browser sends the file straight to the presigned B2 URL through the
  `DirectUpload` JS hook; RPM bytes never traverse Phoenix. The LiveView
  drives the intent lifecycle and polls durable status, so a disconnect
  never cancels the job.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.Intent

  @poll_interval 1500

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <.header>
          Upload RPM
          <:subtitle>
            to
            <.link navigate={~p"/repos/#{@repository.slug}"} class="link">
              {@repository.name}
            </.link>
          </:subtitle>
        </.header>

        <div :if={@phase == :idle} id="direct-upload" phx-hook="DirectUpload">
          <label class="block border-2 border-dashed border-base-300 rounded-lg p-10 text-center cursor-pointer">
            <span class="block text-sm mb-2">
              Choose an RPM file — it uploads directly to storage.
            </span>
            <input type="file" accept=".rpm" class="file-input file-input-bordered" />
          </label>
        </div>

        <div :if={@phase == :uploading} class="space-y-2">
          <p class="text-sm">
            Transferring <span class="font-mono">{@filename}</span> directly to storage…
          </p>
          <progress class="progress w-full"></progress>
        </div>

        <div :if={@phase == :processing} class="space-y-2">
          <p class="text-sm">
            Processing <span class="font-mono">{@filename}</span>
            — status: <span class="badge badge-ghost">{@status}</span>
          </p>
          <progress class="progress w-full"></progress>
          <p class="text-xs text-base-content/60">
            You can leave this page; processing continues in the background.
          </p>
        </div>

        <div :if={@phase == :preview and @preview} class="space-y-4">
          <h2 class="text-lg font-semibold">Preview</h2>
          <div class="grid grid-cols-2 gap-x-8 gap-y-1 text-sm border border-base-300 rounded-lg p-4">
            <div><span class="font-semibold">Name:</span> {@preview["name"]}</div>
            <div>
              <span class="font-semibold">Version:</span>
              {@preview["epoch"]}:{@preview["version"]}-{@preview["release"]}
            </div>
            <div><span class="font-semibold">Arch:</span> {@preview["arch"]}</div>
            <div><span class="font-semibold">License:</span> {@preview["license"]}</div>
            <div class="col-span-2">
              <span class="font-semibold">Summary:</span> {@preview["summary"]}
            </div>
            <div>
              <span class="font-semibold">Files:</span> {length(@preview["files"] || [])}
            </div>
            <div>
              <span class="font-semibold">Dependencies:</span>
              {length(@preview["requires"] || [])}
            </div>
          </div>
          <p class="text-xs text-base-content/60">
            The preview expires after 15 minutes; nothing is published until you confirm.
          </p>
          <div class="flex gap-2">
            <button id="confirm-upload" class="btn btn-primary" phx-click="confirm">
              Confirm upload
            </button>
            <button id="cancel-upload" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </div>

        <div :if={@phase == :done} class="space-y-4">
          <p class="text-success font-semibold">Package uploaded.</p>
          <.link
            navigate={~p"/repos/#{@repository.slug}/package-versions/#{@intent_package_id}"}
            class="btn btn-primary"
          >
            View package
          </.link>
        </div>

        <div :if={@error} class="alert alert-error text-sm" id="upload-error">
          <span>{@error}</span>
          <button class="btn btn-sm" phx-click="reset">Start over</button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    repository = Repositories.get_repository_by_slug(slug)
    user = socket.assigns.current_scope.user

    if repository && DarkZenith.Authorization.can_manage?(user, repository) do
      {:ok, reset_state(assign(socket, :repository, repository))}
    else
      raise DarkZenithWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("select_file", %{"name" => name, "size" => size}, socket)
      when is_integer(size) do
    user = socket.assigns.current_scope.user

    case Uploads.create_intent(user, socket.assigns.repository, %{
           filename: name,
           size: size,
           mode: "web_preview"
         }) do
      {:ok, intent, upload} ->
        {:noreply,
         socket
         |> assign(:intent_id, intent.id)
         |> assign(:intent_package_id, intent.package_id)
         |> assign(:generation, upload.generation)
         |> assign(:filename, intent.original_filename)
         |> assign(:phase, :uploading)
         |> assign(:error, nil)
         |> push_event("start_upload", %{url: upload.url})}

      {:error, :payload_too_large} ->
        {:noreply, assign(socket, :error, "That file exceeds the maximum upload size.")}

      {:error, :quota_exceeded} ->
        {:noreply, assign(socket, :error, "This upload would exceed the owner's storage quota.")}

      {:error, :invalid_filename} ->
        {:noreply, assign(socket, :error, "That filename cannot be used.")}

      {:error, _other} ->
        {:noreply, assign(socket, :error, "The upload could not be started.")}
    end
  end

  def handle_event("uploaded", %{"version_id" => version_id}, socket)
      when is_binary(version_id) do
    with {:ok, intent} <- fetch_intent(socket),
         {:ok, completed} <-
           Uploads.complete_intent(
             socket.assigns.current_scope.user,
             intent,
             socket.assigns.generation,
             version_id
           ) do
      {:noreply,
       socket
       |> assign(:phase, :processing)
       |> assign(:status, completed.status)
       |> schedule_poll()}
    else
      _ ->
        {:noreply, assign(socket, :error, "The transfer could not be verified. Try again.")}
    end
  end

  def handle_event("upload_failed", _params, socket) do
    # After the presigned URL expires a refresh mints a new staging key;
    # before that, the browser can retry the same URL.
    with {:ok, intent} <- fetch_intent(socket),
         {:ok, refreshed, upload} <-
           Uploads.refresh_intent(socket.assigns.current_scope.user, intent) do
      {:noreply,
       socket
       |> assign(:generation, upload.generation)
       |> assign(:intent_id, refreshed.id)
       |> push_event("start_upload", %{url: upload.url})}
    else
      _ ->
        {:noreply, assign(socket, :error, "The direct transfer failed. Start over to retry.")}
    end
  end

  def handle_event("confirm", _params, socket) do
    with {:ok, intent} <- fetch_intent(socket),
         {:ok, _} <- Uploads.confirm_preview(socket.assigns.current_scope.user, intent) do
      {:noreply,
       socket |> assign(:phase, :processing) |> assign(:status, "queued") |> schedule_poll()}
    else
      _ ->
        {:noreply,
         assign(socket, :error, "The preview can no longer be confirmed. Start a new upload.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    with {:ok, intent} <- fetch_intent(socket) do
      Uploads.cancel_intent(socket.assigns.current_scope.user, intent)
    end

    {:noreply, reset_state(socket)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, reset_state(socket)}
  end

  @impl true
  def handle_info(:poll, socket) do
    case fetch_intent(socket) do
      {:ok, %Intent{status: status} = intent} ->
        socket = assign(socket, :status, status)

        case status do
          s when s in ["queued", "processing"] ->
            {:noreply, schedule_poll(socket)}

          "preview_ready" ->
            {:noreply,
             socket |> assign(:phase, :preview) |> assign(:preview, intent.preview_metadata)}

          "succeeded" ->
            {:noreply, assign(socket, :phase, :done)}

          "failed" ->
            {:noreply, assign(socket, :error, "Processing failed: #{intent.last_error_code}.")}

          _other ->
            {:noreply,
             assign(socket, :error, "The upload is no longer active. Start a new upload.")}
        end

      _ ->
        {:noreply, assign(socket, :error, "The upload no longer exists.")}
    end
  end

  defp fetch_intent(socket) do
    case socket.assigns.intent_id &&
           Uploads.get_intent(socket.assigns.repository, socket.assigns.intent_id) do
      %Intent{} = intent -> {:ok, intent}
      _ -> {:error, :not_found}
    end
  end

  defp schedule_poll(socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_interval)
    socket
  end

  defp reset_state(socket) do
    socket
    |> assign(:phase, :idle)
    |> assign(:intent_id, nil)
    |> assign(:intent_package_id, nil)
    |> assign(:generation, nil)
    |> assign(:filename, nil)
    |> assign(:status, nil)
    |> assign(:preview, nil)
    |> assign(:error, nil)
  end
end
