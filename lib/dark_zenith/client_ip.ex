defmodule DarkZenith.ClientIp do
  @moduledoc """
  Client IP resolution (DESIGN.md: Client IP detection).

  With the TCP peer in `TRUSTED_PROXIES`, a valid `CF-Connecting-IP` wins;
  otherwise the `X-Forwarded-For` chain is walked right-to-left skipping
  trusted addresses. An empty `TRUSTED_PROXIES` ignores forwarded headers
  entirely. Per-IP buckets key IPv6 clients by their /64 prefix.
  """

  import Bitwise

  @doc "Resolves the client IP tuple for the connection."
  def resolve(conn) do
    resolve_peer(conn.remote_ip, conn.req_headers)
  end

  @doc """
  Resolves the client IP tuple from a TCP peer address plus a lowercase
  `{name, value}` header list, for surfaces without a full `%Plug.Conn{}`
  (LiveView sockets expose `peer_data` and `x_headers`; `CF-Connecting-IP`
  is not an `x-` header and is absent there, but a trusted Cloudflare proxy
  also appends the client to `X-Forwarded-For`, which resolves identically).
  """
  def resolve_peer(peer, headers) when is_list(headers) do
    if trusted?(peer) do
      cf_connecting_ip(headers) || forwarded_for(headers, peer) || peer
    else
      peer
    end
  end

  @doc "The rate-limit identity for an IP: IPv6 collapses to its /64 prefix."
  def bucket_identity({a, b, c, d}), do: {a, b, c, d}
  def bucket_identity({a, b, c, d, _e, _f, _g, _h}), do: {a, b, c, d}

  @doc "The display string for audit rows."
  def to_string(ip), do: ip |> :inet.ntoa() |> List.to_string()

  ## Trusted proxies

  defp trusted?(ip) do
    Enum.any?(trusted_proxies(), fn {network, prefix} -> in_cidr?(ip, network, prefix) end)
  end

  defp trusted_proxies do
    Application.get_env(:dark_zenith, :trusted_proxies) || []
  end

  @doc """
  Parses a comma-separated `TRUSTED_PROXIES` value into `{network, prefix}`
  entries for the application environment; raises on malformed entries.
  """
  def parse_trusted_proxies(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn entry ->
      entry = String.trim(entry)

      {address, prefix} =
        case String.split(entry, "/", parts: 2) do
          [address] -> {address, nil}
          [address, prefix] -> {address, String.to_integer(prefix)}
        end

      case :inet.parse_strict_address(String.to_charlist(address)) do
        {:ok, ip} -> {ip, prefix || default_prefix(ip)}
        {:error, _} -> raise ArgumentError, "invalid TRUSTED_PROXIES entry: #{entry}"
      end
    end)
  end

  defp default_prefix({_, _, _, _}), do: 32
  defp default_prefix(_ipv6), do: 128

  @doc "Whether `ip` falls inside `network/prefix` (family must match)."
  def in_cidr?(ip, network, prefix) do
    with {:ok, ip_int, bits} <- to_int(ip),
         {:ok, net_int, ^bits} <- to_int(network) do
      shift = bits - prefix
      ip_int >>> shift == net_int >>> shift
    else
      _ -> false
    end
  end

  defp to_int({a, b, c, d}), do: {:ok, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d, 32}

  defp to_int({a, b, c, d, e, f, g, h}) do
    int =
      Enum.reduce([a, b, c, d, e, f, g, h], 0, fn part, acc -> acc <<< 16 ||| part end)

    {:ok, int, 128}
  end

  defp to_int(_other), do: :error

  ## Header handling

  # Exactly one CF-Connecting-IP value that parses as an IP wins.
  defp cf_connecting_ip(headers) do
    case header_values(headers, "cf-connecting-ip") do
      [value] ->
        case :inet.parse_strict_address(String.to_charlist(String.trim(value))) do
          {:ok, ip} -> ip
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp forwarded_for(headers, peer) do
    case header_values(headers, "x-forwarded-for") do
      [chain | _] ->
        chain
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reverse()
        |> Enum.reduce_while(nil, fn entry, _acc ->
          case :inet.parse_strict_address(String.to_charlist(entry)) do
            {:ok, ip} ->
              if trusted?(ip), do: {:cont, nil}, else: {:halt, ip}

            {:error, _} ->
              # An unparseable candidate falls back to the peer.
              {:halt, peer}
          end
        end)

      _ ->
        nil
    end
  end

  defp header_values(headers, name) do
    for {^name, value} <- headers, do: value
  end
end
