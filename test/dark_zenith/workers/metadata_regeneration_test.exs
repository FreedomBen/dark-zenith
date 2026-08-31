defmodule DarkZenith.Workers.MetadataRegenerationTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures
  import Ecto.Query

  alias DarkZenith.Repodata
  alias DarkZenith.Repositories.{MetadataCache, Repository}
  alias DarkZenith.Workers.MetadataRegeneration

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp add_package_and_sync!(repo, binary) do
    package = insert_package_from_rpm!(repo, binary)
    sync_repository_metadata_state!(repo)
    package
  end

  defp reload_cache(repo), do: Repo.get_by!(MetadataCache, repository_id: repo.id)
  defp reload_repo(repo), do: Repo.get!(Repository, repo.id)

  defp gunzip(binary), do: :zlib.gunzip(binary)

  test "regenerates the cache to the captured revision with package entries", %{repo: repo} do
    package = add_package_and_sync!(repo, v4_binary())

    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => repo.id})

    cache = reload_cache(repo)
    assert cache.source_revision == reload_repo(repo).metadata_revision

    primary = gunzip(cache.primary_xml_gz)
    assert primary =~ ~s(packages="1")
    assert primary =~ "<name>dz-fixture</name>"
    assert primary =~ package.sha256
    assert gunzip(cache.filelists_xml_gz) =~ "/usr/share/dz-fixture/data.txt"
    assert gunzip(cache.other_xml_gz) =~ "First changelog entry"
    assert cache.repomd_xml =~ "<revision>1</revision>"

    # repomd checksums match the stored blobs.
    open_sha =
      :crypto.hash(:sha256, primary) |> Base.encode16(case: :lower)

    assert cache.repomd_xml =~ open_sha
  end

  test "the job is a no-op when the cache is already current", %{repo: repo} do
    before_cache = reload_cache(repo)
    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => repo.id})
    assert reload_cache(repo).updated_at == before_cache.updated_at
  end

  test "a slower job never moves the cache backward", %{repo: repo} do
    add_package_and_sync!(repo, minimal_binary())

    {1, _} =
      Repo.update_all(from(c in MetadataCache, where: c.repository_id == ^repo.id),
        set: [source_revision: 9]
      )

    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => repo.id})
    assert reload_cache(repo).source_revision == 9
  end

  test "a counter mismatch aborts without writing the cache", %{repo: repo} do
    add_package_and_sync!(repo, minimal_binary())

    {1, _} =
      Repo.update_all(from(r in Repository, where: r.id == ^repo.id),
        inc: [primary_open_bytes: 1]
      )

    assert {:error, :metadata_counter_mismatch} =
             perform_job(MetadataRegeneration, %{"repository_id" => repo.id})

    assert reload_cache(repo).source_revision == 0
  end

  test "signing failure leaves the previous cache intact", %{repo: repo} do
    add_package_and_sync!(repo, minimal_binary())

    {1, _} =
      Repo.update_all(from(r in Repository, where: r.id == ^repo.id),
        set: [gpg_key_fingerprint: String.duplicate("A", 40)]
      )

    assert {:error, :signing_unavailable} =
             perform_job(MetadataRegeneration, %{"repository_id" => repo.id})

    assert reload_cache(repo).source_revision == 0
  end

  test "a deleted repository is a no-op" do
    assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => Ecto.UUID.generate()})
  end

  test "enqueue_regeneration debounces on repository id", %{repo: repo} do
    Repodata.enqueue_regeneration(repo.id)
    Repodata.enqueue_regeneration(repo.id)

    assert [_only_one] = all_enqueued(worker: MetadataRegeneration)
  end

  test "changing the metadata-signing fingerprint bumps the revision and enqueues", %{
    owner: owner
  } do
    owner = put_user_gpg_fingerprint(owner)
    repo = repository_fixture(owner)
    assert repo.metadata_revision == 0

    {:ok, updated} =
      DarkZenith.Repositories.update_repository(owner, repo, %{
        "gpg_key_fingerprint" => owner.gpg_key_fingerprint
      })

    assert updated.metadata_revision == 1

    assert_enqueued(worker: MetadataRegeneration, args: %{repository_id: repo.id})

    # A non-metadata setting change does not bump the revision.
    {:ok, updated} =
      DarkZenith.Repositories.update_repository(owner, updated, %{"name" => "Renamed"})

    assert updated.metadata_revision == 1
  end
end
