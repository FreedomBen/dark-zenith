defmodule DarkZenith.RepositoriesTest do
  use DarkZenith.DataCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Audit
  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.{MetadataCache, Repository, SlugReservation}

  describe "create_repository/2" do
    setup do
      %{owner: user_fixture()}
    end

    test "creates a repository with defaults and an immediate empty metadata cache", %{
      owner: owner
    } do
      assert {:ok, %Repository{} = repo} =
               Repositories.create_repository(owner, %{slug: "stable", name: "Stable"})

      assert repo.slug == "stable"
      assert repo.name == "Stable"
      assert repo.user_id == owner.id
      assert repo.description == nil
      refute repo.is_public
      refute repo.sign_rpms
      assert repo.rpm_signing_state == "disabled"
      assert repo.metadata_revision == 0
      assert repo.package_count == 0
      assert repo.primary_open_bytes > 0

      cache = Repo.get_by!(MetadataCache, repository_id: repo.id)
      assert cache.source_revision == 0
      assert cache.repomd_xml =~ "<revision>0</revision>"
      assert cache.repomd_xml_asc == nil
      assert :zlib.gunzip(cache.primary_xml_gz) =~ ~s(packages="0")

      reservation = Repo.get!(SlugReservation, "stable")
      assert reservation.repository_id == repo.id
      assert reservation.user_id == owner.id
      assert reservation.retired_at == nil

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "repository.create"
      assert event.actor_id == owner.id
      assert event.target_id == repo.id
    end

    test "the maintained counters equal the empty artifact sizes", %{owner: owner} do
      {:ok, repo} = Repositories.create_repository(owner, %{slug: "sizes", name: "Sizes"})

      generation = DarkZenith.Repodata.generate([], revision: 0, timestamp: 0)
      assert repo.primary_open_bytes == generation.open_sizes.primary
      assert repo.filelists_open_bytes == generation.open_sizes.filelists
      assert repo.other_open_bytes == generation.open_sizes.other
    end

    test "normalizes the slug to lowercase", %{owner: owner} do
      assert {:ok, repo} = Repositories.create_repository(owner, %{slug: "StAbLe2", name: "S"})
      assert repo.slug == "stable2"
    end

    test "validates the slug format", %{owner: owner} do
      for bad <- ["-leading", "_leading", "has space", "has/slash", "é", ""] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Repositories.create_repository(owner, %{slug: bad, name: "N"}),
               "expected #{inspect(bad)} to be rejected"

        assert errors_on(changeset).slug != []
      end

      # 64 characters is the maximum (1 + 63).
      max = "a" <> String.duplicate("b", 63)
      assert {:ok, _} = Repositories.create_repository(owner, %{slug: max, name: "N"})

      over = "a" <> String.duplicate("b", 64)
      assert {:error, changeset} = Repositories.create_repository(owner, %{slug: over, name: "N"})
      assert errors_on(changeset).slug != []
    end

    test "rejects the reserved slug new", %{owner: owner} do
      assert {:error, changeset} =
               Repositories.create_repository(owner, %{slug: "new", name: "N"})

      assert "is reserved" in errors_on(changeset).slug
    end

    test "validates name and description", %{owner: owner} do
      assert {:error, changeset} = Repositories.create_repository(owner, %{slug: unique_slug()})
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: String.duplicate("n", 101)
               })

      assert %{name: ["should be at most 100 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} =
               Repositories.create_repository(owner, %{slug: unique_slug(), name: "bad\nname"})

      assert %{name: ["cannot contain control characters"]} = errors_on(changeset)

      # Description may contain newlines and tabs but no other control chars.
      assert {:ok, repo} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 description: "line one\n\tline two"
               })

      assert repo.description == "line one\n\tline two"

      assert {:error, changeset} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 description: "bad\x01char"
               })

      assert %{description: ["cannot contain control characters"]} = errors_on(changeset)

      # Blank-after-trim description is stored as nil.
      assert {:ok, repo} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 description: "   "
               })

      assert repo.description == nil
    end

    test "rejects a live duplicate slug like a format violation", %{owner: owner} do
      {:ok, _} = Repositories.create_repository(owner, %{slug: "taken", name: "N"})
      other = user_fixture()

      assert {:error, changeset} =
               Repositories.create_repository(other, %{slug: "taken", name: "N"})

      assert "has already been taken" in errors_on(changeset).slug
    end

    test "a fingerprint not matching the owner's current key is rejected", %{owner: owner} do
      assert {:error, changeset} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 gpg_key_fingerprint: String.duplicate("A", 40)
               })

      assert errors_on(changeset).gpg_key_fingerprint != []
    end

    test "sign_rpms requires the fingerprint", %{owner: owner} do
      assert {:error, changeset} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 sign_rpms: true
               })

      assert errors_on(changeset).gpg_key_fingerprint != []
    end

    test "a matching fingerprint requires metadata signing, unavailable until Phase 11", %{
      owner: owner
    } do
      owner = put_user_gpg_fingerprint(owner)

      assert {:error, :signing_unavailable} =
               Repositories.create_repository(owner, %{
                 slug: unique_slug(),
                 name: "N",
                 gpg_key_fingerprint: owner.gpg_key_fingerprint
               })

      # Nothing was committed.
      assert Repo.aggregate(Repository, :count) == 0
      assert Repo.aggregate(SlugReservation, :count) == 0
    end
  end

  describe "slug retirement and revival" do
    setup do
      %{owner: user_fixture()}
    end

    test "the deleting owner can revive their retired slug", %{owner: owner} do
      repo = repository_fixture(owner, %{slug: "mine", name: "First"})
      :ok = Repositories.delete_repository(owner, repo)

      reservation = Repo.get!(SlugReservation, "mine")
      assert reservation.repository_id == nil
      assert reservation.retired_at
      assert reservation.repository_name == "First"

      assert {:ok, revived} =
               Repositories.create_repository(owner, %{slug: "mine", name: "Again"})

      assert revived.slug == "mine"

      reservation = Repo.get!(SlugReservation, "mine")
      assert reservation.repository_id == revived.id
      assert reservation.retired_at == nil
    end

    test "another user cannot claim a retired slug", %{owner: owner} do
      repo = repository_fixture(owner, %{slug: "held", name: "Held"})
      :ok = Repositories.delete_repository(owner, repo)

      other = user_fixture()

      assert {:error, changeset} =
               Repositories.create_repository(other, %{slug: "held", name: "X"})

      assert "has already been taken" in errors_on(changeset).slug
    end

    test "a retired slug whose former owner was deleted cannot be claimed by anyone", %{
      owner: owner
    } do
      repo = repository_fixture(owner, %{slug: "orphan", name: "O"})
      :ok = Repositories.delete_repository(owner, repo)
      Repo.delete!(owner)

      reservation = Repo.get!(SlugReservation, "orphan")
      assert reservation.user_id == nil

      other = user_fixture()

      assert {:error, changeset} =
               Repositories.create_repository(other, %{slug: "orphan", name: "X"})

      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "update_repository/3" do
    setup do
      owner = user_fixture()
      %{owner: owner, repo: repository_fixture(owner)}
    end

    test "updates name, description, and visibility", %{owner: owner, repo: repo} do
      assert {:ok, updated} =
               Repositories.update_repository(owner, repo, %{
                 name: "New Name",
                 description: "desc",
                 is_public: true
               })

      assert updated.name == "New Name"
      assert updated.description == "desc"
      assert updated.is_public

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "repository.update"
    end

    test "admins can update any repository", %{repo: repo} do
      admin = admin_fixture()
      assert {:ok, _} = Repositories.update_repository(admin, repo, %{name: "Admin Named"})
    end

    test "non-owners cannot update", %{repo: repo} do
      other = user_fixture()
      assert {:error, :forbidden} = Repositories.update_repository(other, repo, %{name: "X"})
    end

    test "the slug is immutable", %{owner: owner, repo: repo} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Repositories.update_repository(owner, repo, %{slug: "different"})

      assert "cannot be changed" in errors_on(changeset).slug
    end

    test "rpm_signing_state is server-managed", %{owner: owner, repo: repo} do
      assert {:error, changeset} =
               Repositories.update_repository(owner, repo, %{rpm_signing_state: "enabled"})

      assert errors_on(changeset).rpm_signing_state != []
    end

    test "a non-null fingerprint must match the owner's current key", %{owner: owner, repo: repo} do
      assert {:error, changeset} =
               Repositories.update_repository(owner, repo, %{
                 gpg_key_fingerprint: String.duplicate("B", 40)
               })

      assert errors_on(changeset).gpg_key_fingerprint != []
    end

    test "an explicit nil fingerprint is always permitted", %{owner: owner, repo: repo} do
      assert {:ok, updated} =
               Repositories.update_repository(owner, repo, %{
                 gpg_key_fingerprint: nil,
                 name: "Renamed"
               })

      assert updated.gpg_key_fingerprint == nil
    end

    test "sign_rpms cannot be left true with no fingerprint", %{owner: owner, repo: repo} do
      assert {:error, changeset} = Repositories.update_repository(owner, repo, %{sign_rpms: true})
      assert errors_on(changeset).gpg_key_fingerprint != []
    end

    test "existing_package_strategy is rejected when not enabling on a non-empty repo", %{
      owner: owner,
      repo: repo
    } do
      assert {:error, changeset} =
               Repositories.update_repository(owner, repo, %{
                 existing_package_strategy: "resign"
               })

      assert errors_on(changeset).existing_package_strategy != []

      assert {:error, changeset} =
               Repositories.update_repository(owner, repo, %{
                 sign_rpms: false,
                 existing_package_strategy: "resign"
               })

      assert errors_on(changeset).existing_package_strategy != []
    end

    test "an empty update is rejected", %{owner: owner, repo: repo} do
      assert {:error, %Ecto.Changeset{}} = Repositories.update_repository(owner, repo, %{})
    end
  end

  describe "delete_repository/2" do
    setup do
      owner = user_fixture()
      %{owner: owner, repo: repository_fixture(owner)}
    end

    test "hard-deletes the repository, cache, and retires the slug", %{owner: owner, repo: repo} do
      assert :ok = Repositories.delete_repository(owner, repo)

      refute Repo.get(Repository, repo.id)
      refute Repo.get_by(MetadataCache, repository_id: repo.id)

      reservation = Repo.get!(SlugReservation, repo.slug)
      assert reservation.retired_at
      assert reservation.user_id == owner.id

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "repository.delete"
    end

    test "admins can delete any repository", %{repo: repo} do
      admin = admin_fixture()
      assert :ok = Repositories.delete_repository(admin, repo)
    end

    test "non-owners cannot delete", %{repo: repo} do
      other = user_fixture()
      assert {:error, :forbidden} = Repositories.delete_repository(other, repo)
      assert Repo.get(Repository, repo.id)
    end
  end

  describe "release_retired_slug/2" do
    test "an admin can release a retired slug for general reuse" do
      owner = user_fixture()
      admin = admin_fixture()
      repo = repository_fixture(owner, %{slug: "freed", name: "F"})
      :ok = Repositories.delete_repository(owner, repo)

      assert :ok = Repositories.release_retired_slug(admin, "freed")
      refute Repo.get(SlugReservation, "freed")

      assert [event | _] = Audit.list_events(limit: 1)
      assert event.action == "admin.slug_release"
      assert event.target_type == "slug"
      assert event.metadata == %{"slug" => "freed"}

      # Now anyone can claim it.
      other = user_fixture()
      assert {:ok, _} = Repositories.create_repository(other, %{slug: "freed", name: "New"})
    end

    test "live reservations cannot be released" do
      owner = user_fixture()
      admin = admin_fixture()
      repository_fixture(owner, %{slug: "live-slug", name: "L"})

      assert {:error, :live_reservation} = Repositories.release_retired_slug(admin, "live-slug")
      assert Repo.get(SlugReservation, "live-slug")
    end

    test "unknown slugs return not found" do
      admin = admin_fixture()
      assert {:error, :not_found} = Repositories.release_retired_slug(admin, "missing")
    end

    test "non-admins cannot release" do
      owner = user_fixture()
      repo = repository_fixture(owner, %{slug: "keep", name: "K"})
      :ok = Repositories.delete_repository(owner, repo)

      assert {:error, :forbidden} = Repositories.release_retired_slug(owner, "keep")
    end
  end

  describe "visibility" do
    test "get_repository_by_slug/1 returns the repository" do
      owner = user_fixture()
      repo = repository_fixture(owner, %{slug: "findme", name: "F"})

      assert %Repository{id: id} = Repositories.get_repository_by_slug("findme")
      assert id == repo.id
      refute Repositories.get_repository_by_slug("missing")
    end

    test "list_visible_repositories/1 applies the authorization matrix" do
      owner = user_fixture()
      other = user_fixture()
      admin = admin_fixture()

      {:ok, public_repo} =
        Repositories.create_repository(owner, %{slug: "pub", name: "P", is_public: true})

      {:ok, private_repo} = Repositories.create_repository(owner, %{slug: "priv", name: "Q"})

      anonymous_ids = Repositories.list_visible_repositories(nil) |> Enum.map(& &1.id)
      assert public_repo.id in anonymous_ids
      refute private_repo.id in anonymous_ids

      owner_ids = Repositories.list_visible_repositories(owner) |> Enum.map(& &1.id)
      assert public_repo.id in owner_ids
      assert private_repo.id in owner_ids

      other_ids = Repositories.list_visible_repositories(other) |> Enum.map(& &1.id)
      assert public_repo.id in other_ids
      refute private_repo.id in other_ids

      admin_ids = Repositories.list_visible_repositories(admin) |> Enum.map(& &1.id)
      assert private_repo.id in admin_ids
    end

    test "collaborators see private repositories they can read in listings" do
      owner = user_fixture()
      collaborator = user_fixture()

      {:ok, private_repo} = Repositories.create_repository(owner, %{slug: "collab", name: "C"})
      {:ok, other_private} = Repositories.create_repository(owner, %{slug: "other", name: "O"})

      DarkZenith.CollaboratorsFixtures.collaborator_row_fixture(private_repo, collaborator)

      ids = Repositories.list_visible_repositories(collaborator) |> Enum.map(& &1.id)
      assert private_repo.id in ids
      refute other_private.id in ids
    end

    test "listing orders by slug ascending" do
      owner = user_fixture()
      repository_fixture(owner, %{slug: "zebra", name: "Z", is_public: true})
      repository_fixture(owner, %{slug: "alpha", name: "A", is_public: true})

      slugs = Repositories.list_visible_repositories(nil) |> Enum.map(& &1.slug)
      assert slugs == Enum.sort(slugs)
    end
  end
end
