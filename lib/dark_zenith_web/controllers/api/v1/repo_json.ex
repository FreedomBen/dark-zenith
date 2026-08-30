defmodule DarkZenithWeb.Api.V1.RepoJSON do
  @moduledoc """
  Repository resource shape (DESIGN.md: API Contract Details). The semantic
  `owner_id` field maps to the table's `user_id`; PostgreSQL bigints are
  canonical base-10 strings.
  """

  def data(repository) do
    %{
      "id" => repository.id,
      "owner_id" => repository.user_id,
      "slug" => repository.slug,
      "name" => repository.name,
      "description" => repository.description,
      "is_public" => repository.is_public,
      "gpg_key_fingerprint" => repository.gpg_key_fingerprint,
      "sign_rpms" => repository.sign_rpms,
      "rpm_signing_state" => repository.rpm_signing_state,
      "metadata_revision" => Integer.to_string(repository.metadata_revision),
      "package_count" => Integer.to_string(repository.package_count),
      "inserted_at" => DateTime.to_iso8601(repository.inserted_at),
      "updated_at" => DateTime.to_iso8601(repository.updated_at)
    }
  end
end
