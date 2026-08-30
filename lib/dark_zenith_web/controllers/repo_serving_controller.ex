defmodule DarkZenithWeb.RepoServingController do
  @moduledoc """
  Repository-serving endpoints consumed by RPM clients (DESIGN.md: RPM
  Repository Endpoint; Caching headers; Private Repository Authentication).

  Errors are bare plain-text error-code bodies; query strings are ignored
  entirely; every response sends `Vary: Authorization, Cookie`.
  """

  use DarkZenithWeb, :controller

  alias DarkZenith.Accounts.User
  alias DarkZenith.Repo
  alias DarkZenith.Repositories
  alias DarkZenith.Repositories.MetadataCache

  @metadata_files ~w(repomd.xml repomd.xml.asc primary.xml.gz filelists.xml.gz other.xml.gz)

  plug :put_vary_header

  def repodata(conn, %{"slug" => slug, "filename" => filename}) do
    with_authorized_repository(conn, slug, fn conn, repository ->
      if filename in @metadata_files do
        serve_metadata(conn, repository, filename)
      else
        send_plain_error(conn, 404, "not_found")
      end
    end)
  end

  def gpg_key(conn, %{"slug" => slug}) do
    with_authorized_repository(conn, slug, fn conn, repository ->
      if repository.gpg_key_fingerprint do
        owner = Repo.get!(User, repository.user_id)
        body = [owner.previous_gpg_key_public, owner.gpg_key_public]
        body = body |> Enum.reject(&is_nil/1) |> Enum.join("")

        conn
        |> put_repo_caching_headers(repository)
        |> serve_with_etag(repository, "text/plain; charset=utf-8", body)
      else
        send_plain_error(conn, 404, "not_found")
      end
    end)
  end

  def repo_file(conn, %{"slug" => slug}) do
    with_authorized_repository(conn, slug, fn conn, repository ->
      body = render_repo_file(repository)

      conn
      |> put_repo_caching_headers(repository)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="dark-zenith-#{repository.slug}.repo")
      )
      |> serve_with_etag(repository, "text/plain; charset=utf-8", body)
    end)
  end

  ## Authorization

  defp with_authorized_repository(conn, slug, fun) do
    repository = Repositories.get_repository_by_slug(slug)
    principal = conn.assigns.repo_principal

    cond do
      # Public repository, no explicitly presented failing credential.
      repository && repository.is_public && principal_public_ok?(principal) ->
        fun.(conn, repository)

      # An explicitly presented credential that fails validation is 401 on a
      # public read instead of silently falling back to anonymous access.
      repository && repository.is_public && principal == :invalid_credential ->
        challenge(conn)

      # Anonymous requests to private and nonexistent slugs are challenged
      # identically so the response does not leak repository existence.
      principal == :anonymous ->
        challenge(conn)

      # Everything else follows the private-repository masking rule.
      match?({:authenticated, _, _}, principal) && repository ->
        {:authenticated, user, kind} = principal

        if authorized_for_private?(user, kind, repository) do
          fun.(conn, repository)
        else
          send_plain_error(conn, 404, "not_found")
        end

      true ->
        send_plain_error(conn, 404, "not_found")
    end
  end

  defp principal_public_ok?({:authenticated, _user, _kind}), do: true
  defp principal_public_ok?(:anonymous), do: true
  # A stale/invalid cookie with no Authorization header is ignored on a
  # public read and the request proceeds anonymously.
  defp principal_public_ok?(:invalid_cookie), do: true
  defp principal_public_ok?(_), do: false

  # Private access requires the owner, a collaborator (arrives with the
  # collaborators feature), or an admin; API keys additionally need repo:read.
  defp authorized_for_private?(user, kind, repository) do
    scope_ok? =
      case kind do
        {:api_key, key} -> "repo:read" in key.scopes
        _ -> true
      end

    access_ok? = user.is_admin or user.id == repository.user_id

    scope_ok? and access_ok?
  end

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Dark Zenith"))
    |> send_plain_error(401, "unauthenticated")
  end

  ## Metadata serving

  defp serve_metadata(conn, repository, filename) do
    cache = Repo.get_by(MetadataCache, repository_id: repository.id)

    cond do
      is_nil(cache) or cache.source_revision < repository.metadata_revision ->
        conn
        |> put_resp_header("retry-after", "5")
        |> send_plain_error(503, "metadata_not_ready")

      filename == "repomd.xml.asc" and is_nil(repository.gpg_key_fingerprint) ->
        send_plain_error(conn, 404, "not_found")

      true ->
        {content_type, body} = metadata_body(cache, filename)

        conn
        |> put_repo_caching_headers(repository)
        |> serve_with_etag(repository, content_type, body)
    end
  end

  defp metadata_body(cache, "repomd.xml"), do: {"application/xml", cache.repomd_xml}

  defp metadata_body(cache, "repomd.xml.asc"),
    do: {"text/plain; charset=utf-8", cache.repomd_xml_asc}

  defp metadata_body(cache, "primary.xml.gz"), do: {"application/gzip", cache.primary_xml_gz}
  defp metadata_body(cache, "filelists.xml.gz"), do: {"application/gzip", cache.filelists_xml_gz}
  defp metadata_body(cache, "other.xml.gz"), do: {"application/gzip", cache.other_xml_gz}

  ## .repo rendering

  defp render_repo_file(repository) do
    base = DarkZenithWeb.Endpoint.url()

    credentials =
      if repository.is_public do
        []
      else
        ["username=token", "password=<api-key>"]
      end

    repo_gpgcheck = if repository.gpg_key_fingerprint, do: "1", else: "0"
    gpgcheck = if repository.rpm_signing_state == "enabled", do: "1", else: "0"

    gpgkey =
      if repository.gpg_key_fingerprint do
        ["gpgkey=#{base}/repos/#{repository.slug}/RPM-GPG-KEY"]
      else
        []
      end

    lines =
      [
        "[dark-zenith-#{repository.slug}]",
        "name=Dark Zenith - #{repository.name}",
        "baseurl=#{base}/repos/#{repository.slug}/"
      ] ++
        credentials ++
        [
          "enabled=1",
          "metadata_expire=6h",
          "repo_gpgcheck=#{repo_gpgcheck}",
          "gpgcheck=#{gpgcheck}"
        ] ++ gpgkey

    Enum.join(lines, "\n") <> "\n"
  end

  ## Response helpers

  # Strong ETag over the served bytes; a matching If-None-Match yields an
  # empty 304. Last-Modified is never emitted and If-Modified-Since ignored.
  defp serve_with_etag(conn, _repository, content_type, body) do
    etag = ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")

    conn = put_resp_header(conn, "etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      # These endpoints define exact content types, with charset only where
      # documented, so the header is set directly.
      conn
      |> put_resp_header("content-type", content_type)
      |> send_resp(200, body)
    end
  end

  defp put_repo_caching_headers(conn, repository) do
    value =
      if repository.is_public do
        "public, max-age=0, must-revalidate"
      else
        "private, no-store"
      end

    put_resp_header(conn, "cache-control", value)
  end

  defp send_plain_error(conn, status, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-type", "text/plain; charset=utf-8")
    |> send_resp(status, code)
    |> halt()
  end

  defp put_vary_header(conn, _opts) do
    put_resp_header(conn, "vary", "Authorization, Cookie")
  end
end
