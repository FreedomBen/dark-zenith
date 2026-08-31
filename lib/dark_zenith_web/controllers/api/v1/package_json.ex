defmodule DarkZenithWeb.Api.V1.PackageJSON do
  @moduledoc """
  Package resource shapes (DESIGN.md: API Contract Details). PostgreSQL
  bigints are decimal strings; the internal storage/header fields are never
  exposed.
  """

  def list(package, repository) do
    %{
      "id" => package.id,
      "repository_id" => package.repository_id,
      "rpm_format" => package.rpm_format,
      "name" => package.name,
      "epoch" => Integer.to_string(package.epoch),
      "version" => package.version,
      "release" => package.release,
      "arch" => package.arch,
      "summary" => package.summary,
      "size_package" => Integer.to_string(package.size_package),
      "sha256" => package.sha256,
      "download_path" =>
        "/repos/#{repository.slug}/packages/#{package.id}/" <>
          "#{package.name}-#{package.version}-#{package.release}.#{package.arch}.rpm",
      "inserted_at" => DateTime.to_iso8601(package.inserted_at),
      "updated_at" => DateTime.to_iso8601(package.updated_at)
    }
  end

  def detail(package, repository) do
    Map.merge(list(package, repository), %{
      "description" => package.description,
      "url" => package.url,
      "license" => package.license,
      "size_installed" => Integer.to_string(package.size_installed),
      "size_archive" => package.size_archive && Integer.to_string(package.size_archive),
      "build_time" => package.build_time && DateTime.to_iso8601(package.build_time),
      "rpm_sourcerpm" => package.rpm_sourcerpm,
      "rpm_sourcenevr" => package.rpm_sourcenevr,
      "rpm_group" => package.rpm_group,
      "rpm_vendor" => package.rpm_vendor,
      "rpm_buildhost" => package.rpm_buildhost,
      "requires_count" => count(package.requires),
      "provides_count" => count(package.provides),
      "conflicts_count" => count(package.conflicts),
      "obsoletes_count" => count(package.obsoletes),
      "recommends_count" => count(package.recommends),
      "suggests_count" => count(package.suggests),
      "supplements_count" => count(package.supplements),
      "enhances_count" => count(package.enhances),
      "files_count" => count(package.files),
      "changelogs_count" => count(package.changelogs)
    })
  end

  defp count(list), do: list |> length() |> Integer.to_string()
end
