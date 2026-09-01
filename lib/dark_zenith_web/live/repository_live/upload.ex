defmodule DarkZenithWeb.RepositoryLive.Upload do
  @moduledoc """
  Upload RPM (`GET /repos/:slug/upload`) — direct-to-B2 transfer with
  preview and confirm (DESIGN.md: Web Interface — Upload RPM).

  The browser sends the file straight to the presigned B2 URL through the
  `DirectUpload` JS hook; RPM bytes never traverse Phoenix. The LiveView
  drives the intent lifecycle and polls durable status, so a disconnect
  never cancels the job.

  The page is addressed with an optional `?intent=<id>` — its only
  documented query parameter — patched into the URL when an intent is
  created, so a reload, a remount after an app restart, or a link from
  Upload History reattaches to the viewer's own non-terminal intent
  instead of starting over (DESIGN.md: Upload RPM — Reattaching). Any
  other value renders the standard 404.
  """

  use DarkZenithWeb, :live_view

  alias DarkZenith.Repositories
  alias DarkZenith.Uploads
  alias DarkZenith.Uploads.FailureReason
  alias DarkZenith.Uploads.Intent

  @poll_interval 1500

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width={:data}>
      <div class="space-y-8">
        <div class="space-y-2">
          <Layouts.breadcrumbs segments={[
            {"Repositories", ~p"/repos"},
            {@repository.slug, ~p"/repos/#{@repository.slug}"},
            {"Upload", nil}
          ]} />
          <.header>
            Upload RPM
            <:subtitle>
              to
              <.link navigate={~p"/repos/#{@repository.slug}"} class="link">
                {@repository.name}
              </.link>
            </:subtitle>
          </.header>
        </div>

        <div id="direct-upload" phx-hook="DirectUpload" class="space-y-8">
          <%!-- A reattached awaiting_upload intent: the browser no longer
          holds its file, so it offers only cancellation and a fresh upload. --%>
          <div :if={@phase == :unfinished} id="unfinished-transfer" class="alert alert-soft text-sm">
            <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
            <span class="text-base-content/70">
              The transfer of <span class="font-mono">{@filename}</span>
              did not finish, and this browser no longer holds the file.
              Cancel it, or start a fresh upload below.
            </span>
            <button id="cancel-unfinished" class="btn btn-sm btn-error" phx-click="cancel">
              Cancel
            </button>
          </div>

          <label
            :if={@phase in [:idle, :unfinished]}
            data-drop-zone
            class={[
              "relative flex cursor-pointer flex-col items-center gap-3 overflow-hidden",
              "rounded-box border border-dashed border-base-content/20 px-6 py-14 text-center",
              "dz-dragover:border-primary dz-dragover:bg-base-200"
            ]}
          >
            <Layouts.zenith_mark class="pointer-events-none absolute top-1/2 left-1/2 size-40 -translate-x-1/2 -translate-y-1/2 opacity-[0.06]" />
            <span class="relative text-sm">
              Drag an RPM here, or choose a file — it uploads directly to storage.
            </span>
            <input type="file" accept=".rpm" class="file-input file-input-bordered relative" />
          </label>

          <div :if={@phase == :uploading} class="py-8">
            <Layouts.reticle_spinner label={"Transferring #{@filename} directly to storage…"} />
          </div>

          <div :if={@phase == :processing} class="space-y-3 py-8">
            <Layouts.reticle_spinner label={"Processing #{@filename}…"} />
            <div class="flex justify-center">
              <.badge variant={status_badge(@status)} />
            </div>
            <p class="text-center text-xs text-base-content/70">
              You can leave this page; processing continues in the background.
            </p>
          </div>

          <div :if={@phase == :preview and @preview} class="space-y-4">
            <h2 class="flex items-center gap-3 text-lg font-semibold">
              Preview <.badge variant={:preview_ready} class="badge-sm" />
            </h2>
            <div class="grid grid-cols-2 gap-x-8 gap-y-1 rounded-box border border-base-content/10 p-4 text-sm">
              <div>
                <span class="font-semibold">Name:</span>
                <span class="font-mono">{@preview["name"]}</span>
              </div>
              <div>
                <span class="font-semibold">Version:</span>
                <span class="font-mono">
                  {@preview["epoch"]}:{@preview["version"]}-{@preview["release"]}
                </span>
              </div>
              <div>
                <span class="font-semibold">Arch:</span>
                <span class="font-mono">{@preview["arch"]}</span>
              </div>
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
            <p class="text-xs text-base-content/70">
              <span :if={@preview_remaining}>
                Preview expires in {format_remaining(@preview_remaining)};
              </span>
              <span :if={!@preview_remaining}>The preview expires after 15 minutes;</span>
              nothing is published until you confirm.
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

          <div :if={@error} class="alert alert-error alert-soft text-sm" id="upload-error">
            <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
            <span>{@error}</span>
            <button class="btn btn-sm" phx-click="reset">Start over</button>
          </div>
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

  # `intent` is the route's only documented query parameter. The page's
  # own patch after creating an intent arrives here too and is a no-op;
  # a bare URL after an intent was attached (history navigation) starts
  # fresh; anything else reattaches or 404s.
  @impl true
  def handle_params(params, _uri, socket) do
    case params["intent"] do
      nil ->
        if socket.assigns.intent_id,
          do: {:noreply, reset_state(socket)},
          else: {:noreply, socket}

      id when id == socket.assigns.intent_id ->
        {:noreply, socket}

      id ->
        {:noreply, reattach(socket, id)}
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
         |> push_event("start_upload", %{url: upload.url})
         |> push_patch(to: intent_path(socket, intent.id))}

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

    {:noreply, socket |> reset_state() |> push_patch(to: intent_path(socket, nil))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> reset_state() |> push_patch(to: intent_path(socket, nil))}
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
            entering? = socket.assigns.phase != :preview

            socket =
              socket
              |> assign(:phase, :preview)
              |> assign(:preview, intent.preview_metadata)
              |> assign(:preview_expires_at, intent.expires_at)
              |> assign(:preview_remaining, remaining_seconds(intent.expires_at))

            # Start one countdown chain when the preview first appears.
            if entering?, do: schedule_countdown(socket)
            {:noreply, socket}

          "succeeded" ->
            {:noreply, assign(socket, :phase, :done)}

          "failed" ->
            {:noreply, assign(socket, :error, failure_message(intent))}

          _other ->
            {:noreply,
             assign(socket, :error, "The upload is no longer active. Start a new upload.")}
        end

      _ ->
        {:noreply, assign(socket, :error, "The upload no longer exists.")}
    end
  end

  def handle_info(:countdown, socket) do
    if socket.assigns.phase == :preview and socket.assigns.preview_expires_at do
      case remaining_seconds(socket.assigns.preview_expires_at) do
        remaining when remaining > 0 ->
          schedule_countdown(socket)
          {:noreply, assign(socket, :preview_remaining, remaining)}

        _elapsed ->
          {:noreply,
           socket
           |> assign(:preview_remaining, 0)
           |> assign(:error, "The preview expired. Start a new upload.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp fetch_intent(socket) do
    user = socket.assigns.current_scope.user

    case socket.assigns.intent_id &&
           Uploads.get_intent_for(user, socket.assigns.repository, socket.assigns.intent_id) do
      %Intent{} = intent -> {:ok, intent}
      _ -> {:error, :not_found}
    end
  end

  # Reattaching requires a non-terminal intent the current user initiated
  # in this repository; anything else is the masked 404.
  defp reattach(socket, id) do
    user = socket.assigns.current_scope.user

    case Uploads.get_intent_for(user, socket.assigns.repository, id) do
      %Intent{status: status} = intent
      when status in ["awaiting_upload", "queued", "processing", "preview_ready"] ->
        socket
        |> reset_state()
        |> assign(:intent_id, intent.id)
        |> assign(:intent_package_id, intent.package_id)
        |> assign(:generation, intent.upload_generation)
        |> assign(:filename, intent.original_filename)
        |> assign(:status, status)
        |> enter_phase(intent)

      _ ->
        raise DarkZenithWeb.NotFoundError
    end
  end

  defp enter_phase(socket, %Intent{status: "awaiting_upload"}) do
    assign(socket, :phase, :unfinished)
  end

  defp enter_phase(socket, %Intent{status: "preview_ready"} = intent) do
    socket
    |> assign(:phase, :preview)
    |> assign(:preview, intent.preview_metadata)
    |> assign(:preview_expires_at, intent.expires_at)
    |> assign(:preview_remaining, remaining_seconds(intent.expires_at))
    |> schedule_countdown()
  end

  defp enter_phase(socket, %Intent{}) do
    socket |> assign(:phase, :processing) |> schedule_poll()
  end

  defp intent_path(socket, nil), do: ~p"/repos/#{socket.assigns.repository.slug}/upload"

  defp intent_path(socket, intent_id),
    do: ~p"/repos/#{socket.assigns.repository.slug}/upload?intent=#{intent_id}"

  defp schedule_poll(socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_interval)
    socket
  end

  # The sanitized reason explains which rejection produced the coarse code
  # (DESIGN.md: Upload Failure Reasons); an unrecognized value is dropped.
  defp failure_message(intent) do
    case FailureReason.message(intent.last_error_detail) do
      nil -> "Processing failed: #{intent.last_error_code}."
      message -> "Processing failed: #{message} (#{intent.last_error_detail})"
    end
  end

  defp schedule_countdown(socket) do
    if connected?(socket), do: Process.send_after(self(), :countdown, 1000)
    socket
  end

  defp remaining_seconds(nil), do: nil

  defp remaining_seconds(expires_at) do
    max(DateTime.diff(expires_at, DateTime.utc_now(), :second), 0)
  end

  defp format_remaining(seconds) do
    minutes = div(seconds, 60)
    "#{minutes}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp status_badge("processing"), do: :processing
  defp status_badge(_queued), do: :queued

  defp reset_state(socket) do
    socket
    |> assign(:phase, :idle)
    |> assign(:intent_id, nil)
    |> assign(:intent_package_id, nil)
    |> assign(:generation, nil)
    |> assign(:filename, nil)
    |> assign(:status, nil)
    |> assign(:preview, nil)
    |> assign(:preview_expires_at, nil)
    |> assign(:preview_remaining, nil)
    |> assign(:error, nil)
  end
end
