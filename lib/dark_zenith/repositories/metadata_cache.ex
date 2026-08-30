defmodule DarkZenith.Repositories.MetadataCache do
  @moduledoc """
  Pre-generated repodata blobs served by the repository endpoint (DESIGN.md:
  Repository Metadata Cache). One row per repository; `source_revision` is the
  repository `metadata_revision` the generation ran against.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "repository_metadata_caches" do
    field :primary_xml_gz, :binary
    field :filelists_xml_gz, :binary
    field :other_xml_gz, :binary
    field :repomd_xml, :string
    field :repomd_xml_asc, :string
    field :source_revision, :integer

    belongs_to :repository, DarkZenith.Repositories.Repository

    timestamps(type: :utc_datetime)
  end
end
