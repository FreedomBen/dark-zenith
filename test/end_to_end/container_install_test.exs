defmodule DarkZenith.EndToEnd.ContainerInstallTest do
  @moduledoc """
  A real dnf5 on a fresh Fedora 44 container consumes the repository the
  way the repository page tells a user to: it adds the repository from its
  `dark-zenith.repo` link, installs the uploaded package from it with every
  other repository disabled, and runs the installed program
  (`deploy/dnf_client_check.sh`, driven by `DarkZenith.DnfClientContainer`).

  Everything the client touches is served over real HTTP. A listener started
  here serves the endpoint on the port `DarkZenithWeb.Endpoint.url/0` names,
  so the baseurl in the served `.repo` file resolves inside the container,
  and a second listener serves the in-memory bucket the download redirect
  points at. The upload itself takes the same API and presigned-transfer
  path as the other end-to-end tests.
  """

  # Not async: the endpoint listener has a fixed port, and the listener
  # processes serve requests from this test's sandbox connection.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.DnfClientContainer
  alias DarkZenith.FakeBucket

  @moduletag :container
  @moduletag timeout: :timer.minutes(3)

  @slug "paladin"
  @filename "paladin-0.1.0-1.x86_64.rpm"

  # The installed program has to work, not merely unpack: an encrypt and
  # decrypt round trip through the installed binary, then its version.
  @verify ~S"""
  printf zenith > /tmp/plain &&
  PALADIN_PW=hunter2 paladin --encrypt /tmp/plain --output /tmp/plain.pal --password-env PALADIN_PW &&
  PALADIN_PW=hunter2 paladin --decrypt /tmp/plain.pal --output /tmp/roundtrip --password-env PALADIN_PW &&
  [ "$(cat /tmp/roundtrip)" = zenith ] &&
  paladin --version &&
  echo roundtrip ok
  """

  setup do
    bucket = FakeBucket.start!()
    serve_bucket!(bucket)
    serve_endpoint!()

    owner = user_fixture()

    {:ok, {api_key, _}} =
      Accounts.create_api_key(owner, %{
        name: "ci",
        scopes: ~w(repo:create repo:read package:upload)
      })

    %{bucket: bucket, owner: owner, api_key: api_key, binary: paladin_binary()}
  end

  test "a fresh Fedora 44 dnf5 installs the package from the repository page's link", ctx do
    upload_package!(ctx.api_key, ctx.binary, %{"is_public" => true})
    assert %{success: 1, failure: 0} = drain!(:metadata)

    # The link the repository page hands out, in the command the page shows.
    repo_file_url = "#{DarkZenithWeb.Endpoint.url()}/repos/#{@slug}/dark-zenith.repo"
    page = html_response(get(build_conn(), ~p"/repos/#{@slug}"), 200)
    assert page =~ "dnf5 config-manager addrepo --from-repofile=#{repo_file_url}"

    {output, status} = DnfClientContainer.check([repo_file_url, "paladin", @verify])
    assert status == 0, output

    assert output =~ "+ dnf5 config-manager addrepo --from-repofile=#{repo_file_url}"
    assert output =~ "+ rpm -q paladin\npaladin-0.1.0-1.x86_64\n"
    assert output =~ "installed from: dark-zenith-#{@slug}\n"
    assert output =~ "paladin 0.1.0\nroundtrip ok\ndnf_client_check: ok\n"
  end

  ## Listeners

  # The endpoint runs without its own listener in test; serve it on the port
  # its configured URL names, which is the baseurl the .repo file carries.
  defp serve_endpoint! do
    %URI{host: "localhost", port: port} = URI.parse(DarkZenithWeb.Endpoint.url())

    start_supervised!(
      {Bandit, plug: DarkZenithWeb.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )
  end

  # Serves the in-memory bucket over HTTP on a free port and points presigned
  # URLs at it. The pipeline's own object-storage calls keep going through
  # the Req.Test stub in this process (see `FakeBucket.start!/0`).
  defp serve_bucket!(bucket) do
    listener =
      start_supervised!(
        {Bandit, plug: {FakeBucket, bucket}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    b2 = Application.fetch_env!(:dark_zenith, :b2)
    on_exit(fn -> Application.put_env(:dark_zenith, :b2, b2) end)
    Application.put_env(:dark_zenith, :b2, Keyword.put(b2, :endpoint, "http://127.0.0.1:#{port}"))
  end

  ## The upload

  # The API-driven upload of the fixture package: create the repository,
  # declare the upload, PUT the bytes through the presigned URL over real
  # HTTP, complete, and run the processing pipeline.
  defp upload_package!(token, binary, repository_attrs) do
    attrs = Map.merge(%{"slug" => @slug, "name" => "Paladin"}, repository_attrs)
    created = post(api(token), ~p"/api/v1/repos", attrs)
    assert %{"data" => %{"slug" => @slug}} = json_response(created, 201)

    declared =
      post(api(token), ~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => Integer.to_string(byte_size(binary))
      })

    assert %{"data" => %{"id" => intent_id}, "upload" => upload} = json_response(declared, 201)

    put = transfer(:put, upload["url"], headers: upload["headers"], body: binary)
    assert put.status == 200
    [staged_version] = put.headers["x-amz-version-id"]

    completed =
      post(api(token), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}/complete", %{
        "generation" => upload["generation"],
        "version_id" => staged_version
      })

    assert %{"data" => %{"status" => "queued"}} = json_response(completed, 202)
    assert %{success: 1, failure: 0} = drain!(:rpm_processing)

    status = get(api(token), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}")
    assert %{"data" => %{"status" => "succeeded"}} = json_response(status, 200)
  end

  defp api(token) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  # A real HTTP transfer to object storage, as curl or a browser makes it.
  defp transfer(method, url, opts) do
    {:ok, response} = Req.request([method: method, url: url, retry: false] ++ opts)
    response
  end

  defp drain!(queue) do
    Oban.drain_queue(queue: queue, with_scheduled: true, with_safety: false)
  end
end
