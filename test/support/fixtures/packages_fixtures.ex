defmodule DarkZenith.PackagesFixtures do
  @moduledoc """
  Builds `%Package{}` structs and rows from the checked-in fixture RPMs.
  """

  alias DarkZenith.Packages
  alias DarkZenith.Packages.Package
  alias DarkZenith.Repo
  alias DarkZenith.Rpm

  @doc """
  A `%Package{}` struct parsed from a fixture RPM binary, with real
  `sha256`/`size_package` and deterministic identity/storage placeholders.
  Not persisted; encoder tests use it directly.
  """
  def package_struct_from_rpm(binary, overrides \\ %{}) do
    {:ok, metadata} = Rpm.parse(binary)

    defaults = %{
      id: Ecto.UUID.generate(),
      repository_id: Ecto.UUID.generate(),
      sha256: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower),
      size_package: byte_size(binary),
      storage_path: "repos/fixture/packages/x",
      storage_version_id: "test-version",
      inserted_at: ~U[2026-08-30 12:00:00Z],
      updated_at: ~U[2026-08-30 12:00:00Z]
    }

    attrs =
      metadata
      |> Packages.metadata_attrs()
      |> Map.merge(defaults)
      |> Map.merge(Map.new(overrides))

    struct!(Package, attrs)
  end

  @doc "Inserts a package row for the repository from a fixture RPM binary."
  def insert_package_from_rpm!(repository, binary, overrides \\ %{}) do
    binary
    |> package_struct_from_rpm(Map.merge(%{repository_id: repository.id}, Map.new(overrides)))
    |> Repo.insert!()
  end
end
