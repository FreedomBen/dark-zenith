defmodule DarkZenith.EndToEnd.SignedRepositoryUploadTest do
  @moduledoc """
  The signed-repository lifecycle for a real-world package, driven only
  through public surfaces: the owner logs in and has the server generate a
  GPG key, creates a repository that signs both metadata and packages,
  uploads the RPM through the presigned transfer, and the dnf-facing
  endpoint then serves a key, a `repomd.xml.asc` that verifies against it
  with the real `gpg`, a `.repo` file that turns verification on, and a
  package download.

  RPM signing needs the `rpmsign` tool. The `:rpmsign`-tagged test runs the
  real signer and proves the served package verifies with `rpmkeys`
  against the served key; the other test swaps in `DarkZenith.SigningStub`
  (which copies the package unchanged) so the rest of the lifecycle is
  covered everywhere.
  """

  # Not async: one test overrides the signing implementation.
  use DarkZenithWeb.ConnCase, async: false

  import DarkZenith.AccountsFixtures
  import DarkZenith.RpmFixtures

  alias DarkZenith.FakeBucket
  alias DarkZenith.Gpg

  @slug "paladin-signed"
  @filename "paladin-0.1.0-1.x86_64.rpm"

  setup ctx do
    if ctx[:stub_rpmsign] do
      Application.put_env(:dark_zenith, :signing_impl, DarkZenith.SigningStub)
      on_exit(fn -> Application.delete_env(:dark_zenith, :signing_impl) end)
    end

    owner = user_fixture()
    binary = paladin_binary()
    %{bucket: FakeBucket.start!(), owner: owner, binary: binary}
  end

  defp json(token) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
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

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  # The whole lifecycle up to the served, downloaded package. Returns what
  # the two signing variants assert on differently.
  defp run_lifecycle(ctx) do
    # 1. Log in and have the server generate the signing key.
    login =
      post(json(nil), ~p"/api/v1/auth/login", %{
        "email" => ctx.owner.email,
        "password" => valid_user_password()
      })

    assert %{"data" => %{"token" => "dzst_" <> _ = token}} = json_response(login, 200)

    generated = post(json(token), ~p"/api/v1/gpg_key/generation", %{"algorithm" => "ed25519"})

    assert %{"data" => %{"gpg_key" => key, "private_key" => "-----BEGIN PGP PRIVATE" <> _}} =
             json_response(generated, 200)

    fingerprint = key["fingerprint"]
    assert fingerprint =~ ~r/^[0-9A-F]{40}$/
    assert key["signing_fingerprint"] == fingerprint

    # 2. Create the repository with metadata and package signing on. An
    #    empty repository is signing-ready immediately.
    created =
      post(json(token), ~p"/api/v1/repos", %{
        "slug" => @slug,
        "name" => "Paladin (signed)",
        "is_public" => true,
        "gpg_key_fingerprint" => fingerprint,
        "sign_rpms" => true
      })

    assert %{"data" => repo} = json_response(created, 201)
    assert repo["gpg_key_fingerprint"] == fingerprint
    assert repo["sign_rpms"] == true
    assert repo["rpm_signing_state"] == "enabled"

    # 3. Declare, transfer, and complete the upload.
    declared =
      post(json(token), ~p"/api/v1/repos/#{@slug}/package-uploads", %{
        "filename" => @filename,
        "size" => Integer.to_string(byte_size(ctx.binary))
      })

    assert %{"data" => %{"id" => intent_id}, "upload" => upload} = json_response(declared, 201)

    put = transfer(:put, upload["url"], headers: upload["headers"], body: ctx.binary)
    assert put.status == 200
    [staged_version] = put.headers["x-amz-version-id"]

    completed =
      post(json(token), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}/complete", %{
        "generation" => upload["generation"],
        "version_id" => staged_version
      })

    assert %{"data" => %{"status" => "queued"}} = json_response(completed, 202)

    # 4. Processing signs the package before storing it.
    assert %{success: 1, failure: 0} = drain!(:rpm_processing)

    status = get(json(token), ~p"/api/v1/repos/#{@slug}/package-uploads/#{intent_id}")

    assert %{"data" => %{"status" => "succeeded", "package" => package}} =
             json_response(status, 200)

    assert package["name"] == "paladin"
    assert package["version"] == "0.1.0"
    assert package["arch"] == "x86_64"

    # 5. Regeneration signs the metadata; the dnf endpoint serves key,
    #    signature, and configuration.
    assert %{success: 1, failure: 0} = drain!(:metadata)

    public_key = response(get(build_conn(), "/repos/#{@slug}/RPM-GPG-KEY"), 200)
    assert public_key =~ "BEGIN PGP PUBLIC KEY BLOCK"
    assert public_key == key["public_key"]

    repomd = response(get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml"), 200)
    assert repomd =~ "<revision>1</revision>"

    signature = response(get(build_conn(), "/repos/#{@slug}/repodata/repomd.xml.asc"), 200)
    assert signature =~ "BEGIN PGP SIGNATURE"
    assert :ok = Gpg.verify_detached(public_key, repomd, signature)
    assert {:error, :bad_signature} = Gpg.verify_detached(public_key, repomd <> " ", signature)

    repo_file = response(get(build_conn(), "/repos/#{@slug}/dark-zenith.repo"), 200)
    assert repo_file =~ "repo_gpgcheck=1"
    assert repo_file =~ "gpgcheck=1"
    assert repo_file =~ "gpgkey=#{DarkZenithWeb.Endpoint.url()}/repos/#{@slug}/RPM-GPG-KEY"

    primary = get(build_conn(), "/repos/#{@slug}/repodata/primary.xml.gz")
    primary_xml = :zlib.gunzip(response(primary, 200))
    assert primary_xml =~ "<name>paladin</name>"
    assert primary_xml =~ package["sha256"]

    # 6. The download serves the stored (signed) bytes the API describes.
    redirect = get(build_conn(), package["download_path"])
    assert redirect.status == 302
    [location] = get_resp_header(redirect, "location")

    downloaded = transfer(:get, location, decode_body: false)
    assert downloaded.status == 200
    assert sha256(downloaded.body) == package["sha256"]
    assert Integer.to_string(byte_size(downloaded.body)) == package["size_package"]

    # A signed package is uploaded from the signer's output rather than
    # copied from staging, so only the final object survives cleanup.
    assert %{success: 1, failure: 0} = drain!(:cleanup)
    assert [final_key] = FakeBucket.keys(ctx.bucket)
    assert final_key =~ ~r|^repos/#{@slug}/packages/|

    %{public_key: public_key, downloaded: downloaded.body}
  end

  @tag :stub_rpmsign
  test "signs the metadata with the generated key while RPM signing is stubbed", ctx do
    result = run_lifecycle(ctx)

    # The stub stores the package unchanged.
    assert result.downloaded == ctx.binary
  end

  @tag :rpmsign
  @tag :tmp_dir
  test "signs the package so it verifies with rpmkeys against the served key", ctx do
    result = run_lifecycle(ctx)

    refute result.downloaded == ctx.binary
    assert byte_size(result.downloaded) > byte_size(ctx.binary)

    # What dnf's gpgcheck does: import the served key and check the package.
    results = checksig(ctx.tmp_dir, result.public_key, result.downloaded)
    assert {"Signature", "OK"} in results
    refute Enum.any?(results, &bad?/1)
  end

  # `[{kind, status}]` for every rpmkeys --checksig line, `kind` reduced to
  # "Digest" or "Signature".
  defp checksig(dir, public_key, rpm) do
    dbpath = Path.join(dir, "rpmdb")
    key_path = Path.join(dir, "RPM-GPG-KEY")
    rpm_path = Path.join(dir, "downloaded.rpm")
    File.mkdir_p!(dbpath)
    File.write!(key_path, public_key)
    File.write!(rpm_path, rpm)

    {_, 0} = System.cmd("rpmkeys", ["--dbpath", dbpath, "--import", key_path])

    {output, _} =
      System.cmd("rpmkeys", ["--dbpath", dbpath, "--checksig", "--verbose", rpm_path],
        env: [{"LC_ALL", "C"}],
        stderr_to_stdout: true
      )

    for line <- String.split(output, "\n"),
        [_, name, status] <- [Regex.run(~r/^\s+(.+?):\s+(OK|BAD|NOTFOUND|NOKEY)\b/, line)] do
      kind =
        if String.contains?(String.downcase(name), "signature"), do: "Signature", else: "Digest"

      {kind, status}
    end
  end

  defp bad?({_kind, status}), do: status == "BAD"
end
