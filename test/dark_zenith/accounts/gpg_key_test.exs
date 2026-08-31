defmodule DarkZenith.Accounts.GpgKeyTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.GpgFixtures
  import DarkZenith.RepositoriesFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.Audit
  alias DarkZenith.Crypto.GpgKeyEnvelope
  alias DarkZenith.Repositories
  alias DarkZenith.Workers.{EmailDelivery, MetadataRegeneration}

  setup do
    %{user: user_fixture(), pair: generate_key_pair()}
  end

  describe "upsert_gpg_key/3" do
    test "stores the validated key with an encrypted private envelope", ctx do
      assert {:ok, user} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)

      assert user.gpg_key_fingerprint == ctx.pair.fingerprint
      assert user.gpg_signing_fingerprint == ctx.pair.fingerprint
      assert user.gpg_key_public == ctx.pair.public
      assert user.gpg_key_expires_at == nil
      assert user.gpg_key_expiry_notified_days == []

      assert {:ok, decrypted} = GpgKeyEnvelope.decrypt(user.gpg_key_private, user.id)
      assert decrypted == ctx.pair.private

      assert Enum.any?(Audit.list_events(), &(&1.action == "gpg_key.upload"))
      assert_enqueued(worker: EmailDelivery, args: %{subject: "A GPG signing key was uploaded"})
    end

    test "replacing an existing key requires the transition machinery", ctx do
      {:ok, _} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)
      other = generate_key_pair()

      assert {:error, :replacement_not_implemented} =
               Accounts.upsert_gpg_key(ctx.user, other.public, other.private)
    end

    test "invalid pairs are rejected before any state changes", ctx do
      assert {:error, :validation_failed} =
               Accounts.upsert_gpg_key(ctx.user, "garbage", "garbage")

      assert Repo.get!(Accounts.User, ctx.user.id).gpg_key_fingerprint == nil
    end
  end

  describe "metadata signing end to end" do
    test "a repository created with the fingerprint carries a real signature", ctx do
      {:ok, user} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)

      {:ok, repository} =
        Repositories.create_repository(user, %{
          slug: unique_slug(),
          name: "Signed",
          gpg_key_fingerprint: ctx.pair.fingerprint
        })

      cache =
        Repo.get_by!(DarkZenith.Repositories.MetadataCache, repository_id: repository.id)

      assert cache.repomd_xml_asc =~ "BEGIN PGP SIGNATURE"

      assert :ok =
               DarkZenith.Gpg.verify_detached(
                 ctx.pair.public,
                 cache.repomd_xml,
                 cache.repomd_xml_asc
               )
    end

    test "regeneration signs the fresh repomd for a signing repository", ctx do
      {:ok, user} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)

      {:ok, repository} =
        Repositories.create_repository(user, %{
          slug: unique_slug(),
          name: "Signed",
          gpg_key_fingerprint: ctx.pair.fingerprint
        })

      package = DarkZenith.PackagesFixtures.insert_package_from_rpm!(repository, DarkZenith.RpmFixtures.minimal_binary())
      _ = package
      DarkZenith.PackagesFixtures.sync_repository_metadata_state!(repository)

      assert :ok = perform_job(MetadataRegeneration, %{"repository_id" => repository.id})

      cache =
        Repo.get_by!(DarkZenith.Repositories.MetadataCache, repository_id: repository.id)

      assert cache.source_revision == 1

      assert :ok =
               DarkZenith.Gpg.verify_detached(
                 ctx.pair.public,
                 cache.repomd_xml,
                 cache.repomd_xml_asc
               )
    end

    test "an expired key fails closed on creation and cancels regeneration", ctx do
      {:ok, user} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)

      past = DateTime.add(DateTime.utc_now(:second), -1, :day)

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id),
          set: [gpg_key_expires_at: past]
        )

      user = Repo.get!(Accounts.User, user.id)

      assert {:error, :gpg_key_expired} =
               Repositories.create_repository(user, %{
                 slug: unique_slug(),
                 name: "Expired",
                 gpg_key_fingerprint: ctx.pair.fingerprint
               })
    end
  end

  describe "remove_gpg_key/1" do
    test "refuses while an owned repository uses the key", ctx do
      {:ok, user} = Accounts.upsert_gpg_key(ctx.user, ctx.pair.public, ctx.pair.private)

      {:ok, repository} =
        Repositories.create_repository(user, %{
          slug: unique_slug(),
          name: "Uses key",
          gpg_key_fingerprint: ctx.pair.fingerprint
        })

      assert {:error, :in_use} = Accounts.remove_gpg_key(user)

      :ok = Repositories.delete_repository(user, repository)
      assert :ok = Accounts.remove_gpg_key(user)

      cleared = Repo.get!(Accounts.User, user.id)
      assert cleared.gpg_key_private == nil
      assert cleared.gpg_key_fingerprint == nil
      assert cleared.gpg_signing_fingerprint == nil
      assert Enum.any?(Audit.list_events(), &(&1.action == "gpg_key.remove"))
    end

    test "removing without a key is not found", ctx do
      assert {:error, :not_found} = Accounts.remove_gpg_key(ctx.user)
    end
  end
end
