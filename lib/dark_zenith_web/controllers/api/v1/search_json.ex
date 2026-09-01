defmodule DarkZenithWeb.Api.V1.SearchJSON do
  @moduledoc """
  Search result rows (DESIGN.md: API Contract Details): the package list
  shape plus `repository_slug`, so clients can build browse and download
  URLs without a second lookup.
  """

  alias DarkZenithWeb.Api.V1.PackageJSON

  def row(%{package: package, repository: repository}) do
    package
    |> PackageJSON.list(repository)
    |> Map.put("repository_slug", repository.slug)
  end
end
