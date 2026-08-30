defmodule DarkZenith.Repositories.Repository do
  @moduledoc """
  One hosted RPM repository (DESIGN.md: Data Model — Repositories).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @slug_format ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "repositories" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :gpg_key_fingerprint, :string
    field :sign_rpms, :boolean, default: false
    field :rpm_signing_state, :string, default: "disabled"
    field :signing_transition_id, :binary_id
    field :is_public, :boolean, default: false
    field :metadata_revision, :integer, default: 0
    field :package_count, :integer, default: 0
    field :primary_open_bytes, :integer
    field :filelists_open_bytes, :integer
    field :other_open_bytes, :integer

    belongs_to :user, DarkZenith.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for repository creation. `owner` is the future repository owner;
  the GPG fingerprint rules are validated against their current key.
  """
  def create_changeset(repository, attrs, owner) do
    repository
    |> cast(attrs, [:slug, :name, :description, :is_public, :gpg_key_fingerprint, :sign_rpms])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_format)
    |> validate_reserved_slug()
    |> validate_name_and_description()
    |> validate_gpg_rules(owner)
  end

  @doc """
  Changeset for repository settings updates (DESIGN.md: PATCH matrix). The
  slug is immutable and `rpm_signing_state` is server-managed; attempts to set
  either are rejected. `owner` is the repository owner (who may differ from an
  admin actor).
  """
  def update_changeset(repository, attrs, owner) do
    changeset =
      repository
      |> cast(attrs, [:name, :description, :is_public, :gpg_key_fingerprint, :sign_rpms])
      |> validate_name_and_description()
      |> validate_gpg_rules(owner)
      |> reject_field(attrs, :slug, "cannot be changed")
      |> reject_field(attrs, :rpm_signing_state, "is server-managed")
      |> validate_existing_package_strategy(attrs, repository)

    if changeset.changes == %{} and changeset.errors == [] do
      add_error(changeset, :base, "no effective changes")
    else
      changeset
    end
  end

  defp validate_reserved_slug(changeset) do
    # `new` is reserved for the repository-creation route.
    validate_change(changeset, :slug, fn :slug, slug ->
      if slug == "new", do: [slug: "is reserved"], else: []
    end)
  end

  defp validate_name_and_description(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, fn value ->
      case String.trim(value) do
        "" -> nil
        _ -> value
      end
    end)
    |> validate_length(:name, max: 100)
    |> validate_no_control_characters(:name, ~r/[\x00-\x1F\x7F]/)
    |> validate_length(:description, max: 4096)
    |> validate_no_control_characters(:description, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
  end

  defp validate_no_control_characters(changeset, field, pattern) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.match?(value, pattern) do
        [{field, "cannot contain control characters"}]
      else
        []
      end
    end)
  end

  # A non-null fingerprint must match the owner's current GPG key fingerprint;
  # sign_rpms requires a fingerprint (DESIGN.md: Repositories; PATCH matrix).
  defp validate_gpg_rules(changeset, owner) do
    changeset =
      validate_change(changeset, :gpg_key_fingerprint, fn :gpg_key_fingerprint, fingerprint ->
        if fingerprint == owner.gpg_key_fingerprint do
          []
        else
          [gpg_key_fingerprint: "must match your current GPG key fingerprint"]
        end
      end)

    sign_rpms = get_field(changeset, :sign_rpms)
    fingerprint = get_field(changeset, :gpg_key_fingerprint)

    if sign_rpms && is_nil(fingerprint) do
      add_error(changeset, :gpg_key_fingerprint, "is required when RPM signing is enabled")
    else
      changeset
    end
  end

  defp reject_field(changeset, attrs, field, message) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, to_string(field)) do
      add_error(changeset, field, message)
    else
      changeset
    end
  end

  # `existing_package_strategy` is meaningful only when enabling sign_rpms on
  # a repository that already has packages; any other use is rejected.
  defp validate_existing_package_strategy(changeset, attrs, repository) do
    strategy =
      Map.get(attrs, :existing_package_strategy) || Map.get(attrs, "existing_package_strategy")

    enabling_on_non_empty? =
      get_change(changeset, :sign_rpms) == true and
        repository.sign_rpms == false and
        repository.package_count > 0

    cond do
      is_nil(strategy) and enabling_on_non_empty? ->
        add_error(
          changeset,
          :existing_package_strategy,
          "is required to confirm re-signing existing packages"
        )

      is_nil(strategy) ->
        changeset

      not enabling_on_non_empty? ->
        add_error(
          changeset,
          :existing_package_strategy,
          "is only accepted when enabling RPM signing on a repository with packages"
        )

      strategy != "resign" ->
        add_error(changeset, :existing_package_strategy, "is invalid")

      true ->
        changeset
    end
  end
end
