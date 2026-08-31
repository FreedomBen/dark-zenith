defmodule DarkZenithWeb.PackageDownloadTest do
  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.PackagesFixtures
  import DarkZenith.RepositoriesFixtures
  import DarkZenith.RpmFixtures

  setup do
    owner = user_fixture()
    repo = repository_fixture(owner, %{is_public: true})
    package = insert_package_from_rpm!(repo, v4_binary(), %{storage_version_id: "4_zstored"})
    %{owner: owner, repo: repo, package: package}
  end

  defp download_path(repo, package, filename \\ nil) do
    name = filename || "dz-fixture-1.2.3-4.noarch.rpm"
    "/repos/#{repo.slug}/packages/#{package.id}/#{name}"
  end

  test "302-redirects to a signed exact-version URL", %{conn: conn, repo: repo, package: package} do
    conn = get(conn, download_path(repo, package))

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ package.storage_path
    assert location =~ "versionId=4_zstored"
    assert location =~ "X-Amz-Signature="
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "HEAD gets a method-specific signed URL", %{conn: conn, repo: repo, package: package} do
    get_conn = get(conn, download_path(repo, package))
    head_conn = head(build_conn(), download_path(repo, package))

    assert head_conn.status == 302
    [get_url] = get_resp_header(get_conn, "location")
    [head_url] = get_resp_header(head_conn, "location")
    refute get_url == head_url
  end

  test "the filename segment is cosmetic but validated", %{conn: conn, repo: repo, package: package} do
    renamed = get(conn, download_path(repo, package, "anything-else.rpm"))
    assert renamed.status == 302

    invalid = get(build_conn(), "/repos/#{repo.slug}/packages/#{package.id}/bad name.rpm")
    assert response(invalid, 400) == "invalid_request"

    no_ext = get(build_conn(), "/repos/#{repo.slug}/packages/#{package.id}/name.tar")
    assert response(no_ext, 400) == "invalid_request"
  end

  test "unknown package ids are 404", %{conn: conn, repo: repo} do
    conn = get(conn, "/repos/#{repo.slug}/packages/#{Ecto.UUID.generate()}/x.rpm")
    assert response(conn, 404) == "not_found"

    malformed = get(build_conn(), "/repos/#{repo.slug}/packages/not-a-uuid/x.rpm")
    assert response(malformed, 404) == "not_found"
  end

  test "private repositories challenge anonymous downloads", %{owner: owner} do
    private = repository_fixture(owner, %{is_public: false})
    package = insert_package_from_rpm!(private, minimal_binary())

    conn = get(build_conn(), download_path(private, package, "dz-minimal-0.1-1.noarch.rpm"))
    assert conn.status == 401
    assert response(conn, 401) == "unauthenticated"
  end
end
