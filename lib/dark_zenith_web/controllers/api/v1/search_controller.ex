defmodule DarkZenithWeb.Api.V1.SearchController do
  @moduledoc """
  `GET /api/v1/search/packages` (DESIGN.md: REST API — Search; API Contract
  Details): the REST equivalent of the web search page's package group.
  Visibility follows `GET /api/v1/repos`; `q` is required so the endpoint is
  a search, not an instance-wide package enumeration.
  """

  use DarkZenithWeb, :controller

  action_fallback DarkZenithWeb.Api.FallbackController

  alias DarkZenith.Packages
  alias DarkZenithWeb.Api.{Pagination, RepoAccess, Strict}
  alias DarkZenithWeb.Api.V1.SearchJSON

  def packages(conn, _params) do
    with {:ok, params} <- Strict.validate_query(conn, ["page", "per_page", "q", "arch"]),
         {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, q} <- Strict.parse_filter(params, "q", blank: :require),
         {:ok, arch} <- Strict.parse_filter(params, "arch", blank: :reject) do
      user = RepoAccess.private_read_user(conn.assigns.api_principal)

      {rows, total} =
        user
        |> Packages.search_query(q: q, arch: arch)
        |> Pagination.paginate(page, per_page)

      json(conn, Pagination.envelope(Enum.map(rows, &SearchJSON.row/1), page, per_page, total))
    end
  end
end
