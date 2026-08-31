defmodule DarkZenithWeb.AdminComponents do
  @moduledoc "Shared pieces of the admin surface."

  use Phoenix.Component
  use DarkZenithWeb, :verified_routes

  attr :active, :string, required: true

  def admin_nav(assigns) do
    ~H"""
    <nav class="flex gap-3 text-sm">
      <.link navigate={~p"/admin/users"} class={nav_class(@active, "users")}>Users</.link>
      <.link navigate={~p"/admin/audit"} class={nav_class(@active, "audit")}>Audit log</.link>
      <.link navigate={~p"/admin/slugs"} class={nav_class(@active, "slugs")}>
        Slug reservations
      </.link>
      <.link navigate={~p"/admin/jobs"} class={nav_class(@active, "jobs")}>Background jobs</.link>
    </nav>
    """
  end

  defp nav_class(active, tab) when active == tab, do: "font-semibold underline"
  defp nav_class(_active, _tab), do: "link"
end
