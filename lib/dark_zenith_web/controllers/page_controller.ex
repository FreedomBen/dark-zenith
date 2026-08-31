defmodule DarkZenithWeb.PageController do
  use DarkZenithWeb, :controller

  # The landing page links this many repositories before deferring to /repos.
  @landing_repo_limit 8

  def home(conn, _params) do
    user = conn.assigns[:current_scope] && conn.assigns.current_scope.user
    repositories = DarkZenith.Repositories.list_visible_repositories(user)

    render(conn, :home,
      repositories: Enum.take(repositories, @landing_repo_limit),
      more_repositories?: length(repositories) > @landing_repo_limit,
      base_url: DarkZenithWeb.Endpoint.url()
    )
  end
end
