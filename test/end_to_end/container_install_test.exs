defmodule DarkZenith.EndToEnd.ContainerInstallTest do
  @moduledoc """
  A real dnf5 on a fresh Fedora 44 container consumes the repository the
  way the repository page tells a user to: it adds the repository from its
  `dark-zenith.repo` link, installs the uploaded package from it with every
  other repository disabled, and runs the installed program
  (`deploy/dnf_client_check.sh`, driven by `DarkZenith.DnfClientContainer`).
  The public, private (Basic credentials in a hand-saved `.repo` file), and
  signed (`repo_gpgcheck` and `gpgcheck` against the served key) flows each
  get a container.

  Everything the client touches is served over real HTTP by
  `DarkZenith.LiveListeners`: the endpoint on the port its configured URL
  names, so the baseurl in the served `.repo` file resolves inside the
  container, and the in-memory bucket the download redirect points at. The
  upload itself takes the same API and presigned-transfer path as the other
  end-to-end tests.
  """

  # Not async: see `DarkZenith.LiveListeners`.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.Accounts
  alias DarkZenith.DnfClientContainer
  alias DarkZenith.LiveListeners

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
    LiveListeners.start!()

    owner = user_fixture()

    {:ok, {api_key, _}} =
      Accounts.create_api_key(owner, %{
        name: "ci",
        scopes: ~w(repo:create repo:read package:upload)
      })

    %{owner: owner, api_key: api_key, binary: paladin_binary()}
  end

  test "a fresh Fedora 44 dnf5 installs the package from the repository page's link", ctx do
    upload_package!(ctx.api_key, ctx.binary, %{"is_public" => true})
    assert %{success: 1, failure: 0} = drain!(:metadata)

    # The link the repository page hands out, in the command the page shows.
    page = html_response(get(build_conn(), ~p"/repos/#{@slug}"), 200)
    assert page =~ "dnf5 config-manager addrepo --from-repofile=#{repo_file_url()}"

    {output, status} = DnfClientContainer.check([repo_file_url(), "paladin", @verify])
    assert status == 0, output

    assert output =~ "+ dnf5 config-manager addrepo --from-repofile=#{repo_file_url()}\n"
    # Unsigned, and dnf says so; the signed flow must not.
    assert output =~
             "Warning: skipped OpenPGP checks for 1 package " <>
               "from repository: dark-zenith-#{@slug}\n"

    assert_installed_and_working(output)
  end

  test "a private repository installs with the API key the page has the user save", ctx do
    upload_package!(ctx.api_key, ctx.binary, %{"is_public" => false})
    assert %{success: 1, failure: 0} = drain!(:metadata)

    # config-manager cannot send credentials, and the link challenges
    # anonymous clients, so the page has the user save the file by hand
    # with the key filled in and readable only by root.
    assert response(get(build_conn(), "/repos/#{@slug}/dark-zenith.repo"), 401) ==
             "unauthenticated"

    page = html_response(get(log_in_user(build_conn(), ctx.owner), ~p"/repos/#{@slug}"), 200)
    assert page =~ "/etc/yum.repos.d/dark-zenith-#{@slug}.repo"
    assert page =~ "username=token"
    assert page =~ "sudo chmod 600 /etc/yum.repos.d/dark-zenith-#{@slug}.repo"

    {output, status} =
      DnfClientContainer.check([repo_file_url(), "paladin", @verify],
        env: [{"DZ_CLIENT_PASSWORD", ctx.api_key}]
      )

    assert status == 0, output

    assert output =~
             "+ curl --fail --user token:<redacted> #{repo_file_url()} " <>
               "> /etc/yum.repos.d/dark-zenith-#{@slug}.repo\n" <>
               "+ chmod 600 /etc/yum.repos.d/dark-zenith-#{@slug}.repo\n"

    refute output =~ ctx.api_key
    assert_installed_and_working(output)
  end

  @tag :rpmsign
  test "a signed repository installs with dnf5 verifying metadata and package", ctx do
    # Key generation takes the account's session token.
    login =
      post(api(nil), ~p"/api/v1/auth/login", %{
        "email" => ctx.owner.email,
        "password" => valid_user_password()
      })

    assert %{"data" => %{"token" => "dzst_" <> _ = token}} = json_response(login, 200)

    generated = post(api(token), ~p"/api/v1/gpg_key/generation", %{"algorithm" => "ed25519"})

    assert %{"data" => %{"gpg_key" => %{"fingerprint" => fingerprint}}} =
             json_response(generated, 200)

    upload_package!(token, ctx.binary, %{
      "is_public" => true,
      "gpg_key_fingerprint" => fingerprint,
      "sign_rpms" => true
    })

    assert %{success: 1, failure: 0} = drain!(:metadata)

    # The served configuration turns both checks on against the served key.
    key_url = "#{DarkZenithWeb.Endpoint.url()}/repos/#{@slug}/RPM-GPG-KEY"
    repo_file = response(get(build_conn(), "/repos/#{@slug}/dark-zenith.repo"), 200)
    assert repo_file =~ "repo_gpgcheck=1\ngpgcheck=1\ngpgkey=#{key_url}\n"

    {output, status} = DnfClientContainer.check([repo_file_url(), "paladin", @verify])
    assert status == 0, output

    # --assumeyes accepts the import of the key fetched from gpgkey (once
    # for repomd.xml.asc, once for the package); with it in place dnf
    # verifies both rather than warning that it skipped the checks.
    assert output =~
             " Fingerprint: #{fingerprint}\n From       : #{key_url}\n" <>
               "The key was successfully imported.\n"

    refute output =~ "skipped OpenPGP checks"
    assert_installed_and_working(output)
  end

  defp repo_file_url, do: "#{DarkZenithWeb.Endpoint.url()}/repos/#{@slug}/dark-zenith.repo"

  defp assert_installed_and_working(output) do
    assert output =~ "+ rpm -q paladin\npaladin-0.1.0-1.x86_64\n"
    assert output =~ "installed from: dark-zenith-#{@slug}\n"
    assert output =~ "paladin 0.1.0\nroundtrip ok\ndnf_client_check: ok\n"
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
    conn = put_req_header(build_conn(), "content-type", "application/json")
    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
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
