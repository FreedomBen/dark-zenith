defmodule DarkZenithWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DarkZenithWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} width={:data}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :width, :atom,
    default: :prose,
    values: [:data, :prose, :narrow],
    doc: "page column width (docs/DESIGN_UI.md — Layout system)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-8", width_class(@width)]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp width_class(:data), do: "max-w-7xl"
  defp width_class(:prose), do: "max-w-3xl"
  defp width_class(:narrow), do: "max-w-md"

  @doc """
  Breadcrumb line for data pages (docs/DESIGN_UI.md — Breadcrumbs): path
  segments in Plex Mono, separators muted, current segment unlinked.

  ## Examples

      <Layouts.breadcrumbs segments={[{"Repositories", ~p"/repos"}, {@repo.slug, nil}]} />
  """
  attr :segments, :list,
    required: true,
    doc: "{label, path} tuples in order; a nil path marks the current segment"

  def breadcrumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class="font-mono text-sm">
      <ol class="flex flex-wrap items-center gap-2">
        <li
          :for={{{label, path}, index} <- Enum.with_index(@segments)}
          class="flex items-center gap-2"
        >
          <span :if={index > 0} class="text-base-content/40" aria-hidden="true">/</span>
          <.link :if={path} navigate={path} class="text-base-content/70 hover:text-base-content">
            {label}
          </.link>
          <span :if={!path} aria-current="page" class="text-base-content">{label}</span>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders the Zenith Reticle mark (docs/DESIGN_UI.md — Identity): a horizon ring
  with cardinal ticks in `currentColor` and the zenith star in the primary token.

  ## Examples

      <Layouts.zenith_mark class="size-6" />
  """
  attr :class, :string, default: "size-6"

  def zenith_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" class={@class} aria-hidden="true">
      <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5" />
      <path
        d="M12 1.5v3M22.5 12h-3M12 22.5v-3M1.5 12h3"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
      />
      <path
        d="M12 7 Q12.8 11.2 17 12 Q12.8 12.8 12 17 Q11.2 12.8 7 12 Q11.2 11.2 12 7 Z"
        fill="var(--color-primary)"
      />
    </svg>
    """
  end

  @doc """
  Renders the app footer (docs/DESIGN_UI.md — App shell): mark, name, and version
  on the left; the AGPL §13 corresponding-source link and license on the right.
  """
  def app_footer(assigns) do
    assigns = assign(assigns, version: version(), source_url: DarkZenith.source_url())

    ~H"""
    <footer class="mt-auto flex flex-wrap items-center justify-between gap-x-6 gap-y-2 border-t border-base-content/10 px-4 py-4 text-sm text-base-content/60 sm:px-6 lg:px-8">
      <span class="flex items-center gap-2">
        <.zenith_mark class="size-4" /> Dark Zenith v{@version}
      </span>
      <span class="flex items-center gap-4">
        <a href={@source_url} class="underline-offset-2 hover:text-base-content hover:underline">
          Source
        </a>
        <span>AGPL-3.0-or-later</span>
      </span>
    </footer>
    """
  end

  defp version, do: to_string(Application.spec(:dark_zenith, :vsn))

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
