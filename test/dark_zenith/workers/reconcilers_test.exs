defmodule DarkZenith.Workers.ReconcilersTest do
  use DarkZenith.DataCase, async: true
  use Oban.Testing, repo: DarkZenith.Repo

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures
  import DarkZenith.UploadsFixtures

  alias DarkZenith.Workers.{FinalReconciler, StagingReconciler}

  setup do
    owner = user_fixture()
    %{owner: owner, repo: repository_fixture(owner)}
  end

  defp iso(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp version_xml(key, version, modified_iso) do
    """
    <Version>
      <Key>#{key}</Key>
      <VersionId>#{version}</VersionId>
      <LastModified>#{modified_iso}</LastModified>
    </Version>
    """
  end

  defp stub_listing(prefix, version_blocks) do
    {:ok, deletes} = Agent.start_link(fn -> [] end)

    Req.Test.stub(DarkZenith.B2Stub, fn conn ->
      case conn.method do
        "GET" ->
          assert conn.query_string =~ "prefix=" <> URI.encode_www_form(prefix)

          body = """
          <?xml version="1.0" encoding="UTF-8"?>
          <ListVersionsResult>
            <IsTruncated>false</IsTruncated>
            #{Enum.join(version_blocks, "\n")}
          </ListVersionsResult>
          """

          Plug.Conn.send_resp(conn, 200, body)

        "DELETE" ->
          %{"versionId" => version} = URI.decode_query(conn.query_string)
          key = String.replace_prefix(conn.request_path, "/dz-bucket/", "")
          Agent.update(deletes, &[{key, version} | &1])
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    deletes
  end

  test "staging reconciler preserves live intents and young versions", ctx do
    {:ok, awaiting, _} =
      DarkZenith.Uploads.create_intent(ctx.owner, ctx.repo, %{
        filename: "a.rpm",
        size: 10,
        mode: "api"
      })

    accepted_reservation = reservation_row_fixture(ctx.owner, ctx.repo)

    accepted =
      awaiting_intent_row_fixture(ctx.repo, ctx.owner, accepted_reservation, %{
        status: "queued",
        staging_version_id: "4_zaccepted",
        next_attempt_at: DateTime.utc_now(:second),
        upload_url_expires_at: nil,
        expires_at: nil
      })

    old = iso(-3 * 3600)

    deletes =
      stub_listing("staging/uploads/", [
        # Current key of an unexpired awaiting intent: every version kept.
        version_xml(awaiting.staging_path, "4_zv1", old),
        version_xml(awaiting.staging_path, "4_zv2", old),
        # Accepted exact version kept; a sibling version at that key is not.
        version_xml(accepted.staging_path, "4_zaccepted", old),
        version_xml(accepted.staging_path, "4_zreplayed", old),
        # A young orphan survives the grace period.
        version_xml("staging/uploads/young.rpm", "4_zyoung", iso(-60)),
        # An old orphan is removed.
        version_xml("staging/uploads/orphan.rpm", "4_zorphan", old)
      ])

    assert :ok = perform_job(StagingReconciler, %{})

    deleted = Agent.get(deletes, &Enum.sort/1)

    assert deleted == [
             {accepted.staging_path, "4_zreplayed"},
             {"staging/uploads/orphan.rpm", "4_zorphan"}
           ]
  end

  test "final reconciler deletes only old unreferenced versions", ctx do
    package = insert_package_from_rpm!(ctx.repo, v4_binary(), %{storage_version_id: "4_zlive"})

    old = iso(-25 * 3600)

    deletes =
      stub_listing("repos/", [
        version_xml(package.storage_path, "4_zlive", old),
        version_xml(package.storage_path, "4_zsuperseded", old),
        version_xml("repos/gone/packages/x/y/z.rpm", "4_zold", old),
        version_xml("repos/gone/packages/x/y/z2.rpm", "4_zrecent", iso(-3600))
      ])

    assert :ok = perform_job(FinalReconciler, %{})

    deleted = Agent.get(deletes, &Enum.sort/1)

    assert deleted == [
             {package.storage_path, "4_zsuperseded"},
             {"repos/gone/packages/x/y/z.rpm", "4_zold"}
           ]
  end
end
