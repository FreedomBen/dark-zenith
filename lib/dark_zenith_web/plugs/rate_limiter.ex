defmodule DarkZenithWeb.Plugs.RateLimiter do
  @moduledoc """
  HTTP rate limiting (DESIGN.md: Rate Limiting). Mounted per pipeline after
  the credential plugs, so a successfully authenticated principal selects
  its per-user bucket while failed or absent credentials use the per-IP
  bucket. Counters are consumed before controller work; rejected requests
  keep their consumed slots. Responses always carry `X-RateLimit-*`
  headers describing the governing bucket; a rejection sets `Retry-After`
  and renders 429 in the surface's own format.
  """

  import Plug.Conn

  alias DarkZenith.ClientIp
  alias DarkZenith.RateLimit

  @bypass_paths [["health"], ["favicon.ico"], ["robots.txt"]]

  def init(opts), do: Keyword.fetch!(opts, :surface)

  def call(conn, surface) do
    if bypass?(conn) do
      conn
    else
      user = authenticated_user(conn, surface)
      ip_identity = conn |> ClientIp.resolve() |> ClientIp.bucket_identity()
      buckets = classify(conn, surface, user, ip_identity)

      {allowed?, governing} = RateLimit.hit(buckets)
      conn = put_rate_headers(conn, governing)

      if allowed? do
        conn
      else
        reject(conn, surface, user, governing)
      end
    end
  end

  ## Classification

  defp bypass?(%{path_info: path}), do: path in @bypass_paths or match?(["assets" | _], path)

  defp classify(conn, :repo_serving, user, ip_identity) do
    download? = match?(["repos", _slug, "packages", _id, _file], conn.path_info)

    case {download?, user} do
      {true, %{id: id}} -> [{:download_auth, id}]
      {true, nil} -> [{:download_unauth, ip_identity}]
      {false, %{id: id}} -> [{:general_auth, id}]
      {false, nil} -> [{:general_unauth, ip_identity}]
    end
  end

  defp classify(conn, :api, user, ip_identity) do
    case conn.path_info do
      ["api", "v1", "auth", "login"] when conn.method == "POST" ->
        auth_attempt_buckets(ip_identity, conn.body_params["email"])

      path ->
        general = general_bucket(user, ip_identity)
        general ++ specialized_api(conn.method, path, user)
    end
  end

  defp classify(conn, :browser, user, ip_identity) do
    case {conn.method, conn.path_info} do
      {"POST", ["users", "log-in"]} ->
        auth_attempt_buckets(ip_identity, get_in(conn.body_params, ["user", "email"]))

      _other ->
        general_bucket(user, ip_identity)
    end
  end

  defp general_bucket(%{id: id}, _ip), do: [{:general_auth, id}]
  defp general_bucket(nil, ip_identity), do: [{:general_unauth, ip_identity}]

  # Authentication attempts use the IP bucket plus, for a syntactically
  # valid email, a normalized-email bucket — in lieu of the general bucket.
  defp auth_attempt_buckets(ip_identity, email) do
    [{:auth_attempt_ip, ip_identity} | email_bucket(email)]
  end

  defp email_bucket(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if normalized =~ ~r/^[^@,;\s]+@[^@,;\s]+$/ and String.length(normalized) <= 160 do
      [{:auth_attempt_email, normalized}]
    else
      []
    end
  end

  defp email_bucket(_email), do: []

  defp specialized_api("POST", ["api", "v1", "repos"], %{id: id}), do: [{:repo_create, id}]
  defp specialized_api("POST", ["api", "v1", "api_keys"], %{id: id}), do: [{:api_key_create, id}]

  defp specialized_api(method, ["api", "v1", "gpg_key" | rest], %{id: id})
       when method in ["PUT", "DELETE", "POST"] and rest in [[], ["revocation"]],
       do: [{:gpg_key_mutation, id}]

  defp specialized_api("POST", ["api", "v1", "repos", _slug, "collaborators"], %{id: id}),
    do: [{:collaborator_add, id}]

  defp specialized_api("POST", ["api", "v1", "repos", _slug, "package-uploads"], %{id: id}),
    do: [{:upload_intent, id}]

  defp specialized_api(_method, _path, _user), do: []

  ## Identity

  defp authenticated_user(conn, :api) do
    case conn.assigns[:api_principal] do
      {:authenticated, user, _kind} -> user
      _ -> nil
    end
  end

  defp authenticated_user(conn, :repo_serving) do
    case conn.assigns[:repo_principal] do
      {:authenticated, user, _kind} -> user
      _ -> nil
    end
  end

  defp authenticated_user(conn, :browser) do
    case conn.assigns[:current_scope] do
      %{user: %{id: _} = user} -> user
      _ -> nil
    end
  end

  ## Responses

  @doc false
  def put_rate_headers(conn, governing) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(governing.limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(governing.remaining))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(governing.reset))
  end

  defp reject(conn, surface, user, governing) do
    retry_after = max(governing.reset - System.os_time(:second), 1)
    conn = put_resp_header(conn, "retry-after", Integer.to_string(retry_after))

    case surface do
      :repo_serving ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "rate_limited")
        |> halt()

      :api ->
        message =
          if user do
            "Request exceeded the applicable rate limit"
          else
            "Request exceeded the applicable rate limit. " <>
              "Create an account and authenticate for higher limits."
          end

        DarkZenithWeb.Api.Errors.send_error(conn, 429, "rate_limited", message: message)

      :browser ->
        body =
          if user do
            "Too many requests. Please retry in #{retry_after} seconds."
          else
            "Too many requests. Please retry in #{retry_after} seconds. " <>
              "Sign in for higher rate limits."
          end

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(429, "<html><body><h1>429</h1><p>#{body}</p></body></html>")
        |> halt()
    end
  end
end
