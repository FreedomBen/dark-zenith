defmodule DarkZenithWeb.AdminComponents do
  @moduledoc """
  Shared frame for the admin surface (docs/DESIGN_UI.md — Page notes: Admin):
  one Admin title block and a sub-nav tab row over each of the six views.
  """

  use Phoenix.Component
  use DarkZenithWeb, :verified_routes

  import DarkZenithWeb.CoreComponents

  defp tabs do
    [
      {"users", "Users", ~p"/admin/users"},
      {"jobs", "Jobs", ~p"/admin/jobs"},
      {"transitions", "Transitions", ~p"/admin/transitions"},
      {"audit", "Audit", ~p"/admin/audit"},
      {"slugs", "Slugs", ~p"/admin/slugs"},
      {"uploads", "Uploads", ~p"/admin/uploads"}
    ]
  end

  @doc """
  Renders the admin page frame: the Admin title, the one-line muted
  description of the active view, the Users / Jobs / Transitions / Audit /
  Slugs / Uploads tab row, and the view content.

  ## Examples

      <AdminComponents.admin_page active="users" subtitle="Accounts and limits.">
        ...
      </AdminComponents.admin_page>
  """
  attr :active, :string, required: true, values: ~w(users jobs transitions audit slugs uploads)
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def admin_page(assigns) do
    assigns = assign(assigns, :tabs, tabs())

    ~H"""
    <div class="space-y-6">
      <.header>
        Admin
        <:subtitle :if={@subtitle}>{@subtitle}</:subtitle>
      </.header>

      <%!-- links between pages, not in-page panels — nav + aria-current, no tablist roles --%>
      <nav aria-label="Admin sections" class="tabs tabs-border">
        <.link
          :for={{key, label, path} <- @tabs}
          navigate={path}
          class={["tab", @active == key && "tab-active"]}
          aria-current={@active == key && "page"}
        >
          {label}
        </.link>
      </nav>

      {render_slot(@inner_block)}
    </div>
    """
  end
end
