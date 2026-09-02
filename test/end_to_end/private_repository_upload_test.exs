defmodule DarkZenith.EndToEnd.PrivateRepositoryUploadTest do
  @moduledoc """
  The private-repository lifecycle for a real-world package, driven only
  through public surfaces and seen from every kind of client: the owner
  (API key from the login and key-creation endpoints), a collaborator added
  through the API and notified by email, a stranger holding a valid key,
  an anonymous dnf, and a browser session. Ends by flipping the repository
  public and watching the credential requirement disappear.
  """

  use DarkZenithWeb.ConnCase, async: true

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures, only: [paladin_binary: 0]

  alias DarkZenith.FakeBucket

  @slug "paladin-private"
  @filename "paladin-0.1.0-1.x86_64.rpm"
  @challenge ~s(Basic realm="Dark Zenith")

  setup do
    %{
      bucket: FakeBucket.start!(),
      owner: user_fixture(),
      collaborator: user_fixture(),
      stranger: user_fixture(),
      binary: paladin_binary()
    }
  end

  defp json(token) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
  end

  # What dnf sends for `username=token` / `password=<api-key>`.
  defp dnf(api_key) do
    put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("token:" <> api_key))
  end

  # Logs the user in and mints an API key, both through the API.
  defp api_key_for(user, scopes) do
    login =
      post(json(nil), ~p"/api/v1/auth/login", %{
        "email" => user.email,
        "password" => valid_user_password()
      })

    assert %{"data" => %{"token" => session}} = json_response(login, 200)

    created = post(json(session), ~p"/api/v1/api_keys", %{"name" => "ci", "scopes" => scopes})
    assert %{"data" => %{"key" => "dzak_" <> _ = key}} = json_response(created, 201)
    key
  end

  defp transfer(method, url, opts) do
    {:ok, response} =
      Req.request(
        [method: method, url: url, plug: {Req.Test, DarkZenith.B2Stub}, retry: false] ++ opts
      )

    response
  end

  defp drain!(queue) do
    Oban.drain_queue(queue: queue, with_scheduled: true, with_safety: false)
  end

  # Every email the test-adapter mailer has delivered to this process so far.
  defp delivered_emails(acc \\ []) do
    receive do
      {:email, email} -> delivered_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "serves the package only to the owner and collaborators until made public", ctx do
    owner_key = api_key_for(ctx.owner, ~w(repo:create repo:read repo:update package:upload))

    # 1. Create the private repository.
    created =
      post(json(owner_key), ~p"/api/v1/repos", %{
        "slug" => @slug,
        "name" => "Paladin (private)",
        "is_public" => false
      })

    assert %{"data" => %{"slug" => @slug, "is_public" => false}} = json_response(created, 201)

    # 2. It does not exist for anonymous API clients.
    assert %{"data" => listed} = json_response(get(build_conn(), ~p"/api/v1/repos"), 200)
    refute Enum.any?(listed, &(&1["slug"] == @slug))

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(build_conn(), ~p"/api/v1/repos/#{@slug}"), 404)

    # 3. Anonymous dnf gets the Basic challenge, identical to a slug that
    #    does not exist.
    private = get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml")
    missing = get(build_conn(), "/repos/no-such-repo/repodata/repomd.xml")
    assert response(private, 401) == "unauthenticated"
    assert get_resp_header(private, "www-authenticate") == [@challenge]
    assert {missing.status, missing.resp_body} == {private.status, private.resp_body}
    assert get_resp_header(missing, "www-authenticate") == [@challenge]

    # 4. The owner uploads the package.
    declared =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => Integer.to_string(byte_size(ctx.binary))
      })

    assert %{"data" => %{"id" => intent_id}, "upload" => upload} = json_response(declared, 201)

    put = transfer(:put, upload["url"], headers: upload["headers"], body: ctx.binary)
    assert put.status == 200
    [staged_version] = put.headers["x-amz-version-id"]

    completed =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}/complete", %{
        "generation" => upload["generation"],
        "version_id" => staged_version
      })

    assert %{"data" => %{"status" => "queued"}} = json_response(completed, 202)
    assert %{success: 1, failure: 0} = drain!(:rpm_processing)

    status = get(json(owner_key), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}")

    assert %{"data" => %{"status" => "succeeded", "package" => package}} =
             json_response(status, 200)

    assert package["name"] == "paladin"
    assert %{success: 1, failure: 0} = drain!(:metadata)

    # 5. The owner's dnf client: credentials in the header, never in the
    #    generated file or the storage redirect.
    repo_file = get(dnf(owner_key), "/repos/#{@slug}/dark-zenith.repo")
    body = response(repo_file, 200)
    assert body =~ "username=token"
    assert body =~ "password=<api-key>"
    assert body =~ "repo_gpgcheck=0"
    assert body =~ "gpgcheck=0"
    refute body =~ owner_key
    assert get_resp_header(repo_file, "cache-control") == ["private, no-store"]

    repomd = get(dnf(owner_key), "/repos/#{@slug}/repodata/repomd.xml")
    assert response(repomd, 200) =~ "<revision>1</revision>"
    assert get_resp_header(repomd, "cache-control") == ["private, no-store"]

    primary = get(dnf(owner_key), "/repos/#{@slug}/repodata/primary.xml.gz")
    assert :zlib.gunzip(response(primary, 200)) =~ "<name>paladin</name>"

    redirect = get(dnf(owner_key), package["download_path"])
    assert redirect.status == 302
    [location] = get_resp_header(redirect, "location")
    refute location =~ owner_key

    downloaded = transfer(:get, location, decode_body: false)
    assert downloaded.status == 200
    assert downloaded.body == ctx.binary

    # A script holding the key as a bearer token gets the same access.
    assert response(get(json(owner_key), "/repos/#{@slug}/dark-zenith.repo"), 200) =~ "baseurl="

    # 6. A stranger's valid key, and an invalid key, are masked as not found.
    stranger_key = api_key_for(ctx.stranger, ~w(repo:read))

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(json(stranger_key), ~p"/api/v1/repos/#{@slug}"), 404)

    assert response(get(dnf(stranger_key), "/repos/#{@slug}/repodata/repomd.xml"), 404) ==
             "not_found"

    assert response(get(dnf(stranger_key), package["download_path"]), 404) == "not_found"

    assert response(get(dnf("dzak_not_a_real_key"), "/repos/#{@slug}/repodata/repomd.xml"), 404) ==
             "not_found"

    # 7. The owner adds a collaborator, who is notified by email.
    added =
      post(json(owner_key), ~p"/api/v1/repos/#{@slug}/collaborators", %{
        "email" => ctx.collaborator.email
      })

    assert %{"data" => %{"type" => "collaborator", "user_id" => collaborator_id}} =
             json_response(added, 201)

    assert collaborator_id == ctx.collaborator.id

    # Confirmation and new-API-key notices share the queue; the access
    # notice is among them.
    assert %{failure: 0} = drain!(:mailers)
    emails = delivered_emails()

    assert notice =
             Enum.find(emails, fn email ->
               email.to == [{"", ctx.collaborator.email}] and email.text_body =~ "/repos/#{@slug}"
             end)

    assert notice.subject == "You now have access to Paladin (private)"

    # 8. The collaborator reads and downloads with their own key but cannot
    #    upload, even holding the scope.
    collaborator_key = api_key_for(ctx.collaborator, ~w(repo:read package:upload))

    assert %{"data" => %{"slug" => @slug}} =
             json_response(get(json(collaborator_key), ~p"/api/v1/repos/#{@slug}"), 200)

    assert response(get(dnf(collaborator_key), "/repos/#{@slug}/repodata/repomd.xml"), 200) =~
             "<revision>1</revision>"

    assert get(dnf(collaborator_key), package["download_path"]).status == 302

    refused =
      post(json(collaborator_key), ~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => "1"
      })

    assert %{"error" => %{"code" => "forbidden"}} = json_response(refused, 403)

    # 9. The owner's browser session authorizes the direct download link.
    assert get(log_in_user(build_conn(), ctx.owner), package["download_path"]).status == 302

    # 10. Making the repository public drops the credential requirement.
    published = patch(json(owner_key), ~p"/api/v1/repos/#{@slug}", %{"is_public" => true})
    assert %{"data" => %{"is_public" => true}} = json_response(published, 200)

    assert %{"data" => %{"slug" => @slug}} =
             json_response(get(build_conn(), ~p"/api/v1/repos/#{@slug}"), 200)

    open = get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml")
    assert response(open, 200) =~ "<revision>1</revision>"
    assert get_resp_header(open, "cache-control") == ["public, max-age=0, must-revalidate"]

    public_file = response(get(build_conn(), "/repos/#{@slug}/dark-zenith.repo"), 200)
    refute public_file =~ "password="
    assert get(build_conn(), package["download_path"]).status == 302
  end
end
