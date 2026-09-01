defmodule DarkZenithWeb.Api.Strict do
  @moduledoc """
  Strict request parsing for `/api/v1` (DESIGN.md: API Contract Details).

  Routes reject every query parameter name they do not document; repeated
  keys are rejected even with identical values; malformed percent encoding or
  non-UTF-8 query bytes are `400 invalid_request`. JSON bodies reject unknown
  fields.
  """

  @doc """
  Validates the query string against the allowed parameter names. Returns
  `{:ok, params_map}`, `{:error, :invalid_request}` for undecodable queries,
  or `{:error, :validation_failed, details}` for unknown/repeated keys.
  """
  def validate_query(conn, allowed \\ []) do
    with {:ok, pairs} <- decode_query_pairs(conn.query_string) do
      keys = Enum.map(pairs, &elem(&1, 0))

      cond do
        keys != Enum.uniq(keys) ->
          {:error, :validation_failed, %{"query" => ["repeated parameter"]}}

        unknown = Enum.find(keys, &(&1 not in allowed)) ->
          {:error, :validation_failed, %{unknown => ["is not a supported parameter"]}}

        true ->
          {:ok, Map.new(pairs)}
      end
    end
  end

  @filter_max 256

  @doc """
  Parses a filter-string query parameter under the shared rules (DESIGN.md:
  API Contract Details): trimmed and capped at #{@filter_max} characters.
  The `:blank` option decides how an empty-after-trim value is handled —
  `:absent` treats it (and a missing parameter) as `{:ok, nil}`, `:reject`
  rejects blank values, and `:require` additionally rejects a missing
  parameter.
  """
  def parse_filter(params, key, blank: blank_rule) do
    case Map.fetch(params, key) do
      :error when blank_rule == :require ->
        {:error, :validation_failed, %{key => ["can't be blank"]}}

      :error ->
        {:ok, nil}

      {:ok, raw} ->
        value = String.trim(raw)

        cond do
          String.length(value) > @filter_max ->
            {:error, :validation_failed, %{key => ["is too long"]}}

          value == "" and blank_rule == :absent ->
            {:ok, nil}

          value == "" ->
            {:error, :validation_failed, %{key => ["must not be blank"]}}

          true ->
            {:ok, value}
        end
    end
  end

  @doc """
  Requires a JSON request body: `Content-Type: application/json` and an
  object whose keys are a subset of `allowed`. `required` keys must be
  present. Returns `{:ok, body_params}` or an error tuple.
  """
  def validate_json_body(conn, allowed, required \\ []) do
    content_type = List.first(Plug.Conn.get_req_header(conn, "content-type") || [])

    cond do
      is_nil(content_type) or not String.starts_with?(content_type, "application/json") ->
        {:error, :invalid_request}

      not is_map(conn.body_params) or Map.has_key?(conn.body_params, "_json") ->
        {:error, :invalid_request}

      true ->
        params = conn.body_params
        keys = Map.keys(params)

        cond do
          unknown = Enum.find(keys, &(&1 not in allowed)) ->
            {:error, :validation_failed, %{unknown => ["is not a supported field"]}}

          missing = Enum.find(required, &(not Map.has_key?(params, &1))) ->
            {:error, :validation_failed, %{missing => ["can't be blank"]}}

          true ->
            {:ok, params}
        end
    end
  end

  @doc """
  Accepts an absent body or an empty JSON object; any body field is
  rejected. For POST endpoints that document no body.
  """
  def validate_empty_body(conn) do
    case conn.body_params do
      params when params == %{} ->
        :ok

      %{"_json" => _} ->
        {:error, :invalid_request}

      params when is_map(params) ->
        unknown = params |> Map.keys() |> List.first()
        {:error, :validation_failed, %{unknown => ["is not a supported field"]}}

      _other ->
        {:error, :invalid_request}
    end
  end

  # Decodes the raw query string, rejecting malformed percent encoding and
  # bytes that are not valid UTF-8 after decoding.
  defp decode_query_pairs(""), do: {:ok, []}

  defp decode_query_pairs(query_string) do
    if valid_percent_encoding?(query_string) do
      pairs =
        query_string
        |> String.split("&", trim: true)
        |> Enum.map(fn segment ->
          case String.split(segment, "=", parts: 2) do
            [key] -> {decode_component(key), ""}
            [key, value] -> {decode_component(key), decode_component(value)}
          end
        end)

      if Enum.all?(pairs, fn {k, v} -> is_binary(k) and is_binary(v) end) do
        {:ok, pairs}
      else
        {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp valid_percent_encoding?(string) do
    not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, string)
  end

  defp decode_component(component) do
    decoded = component |> String.replace("+", " ") |> URI.decode()
    if String.valid?(decoded), do: decoded, else: :invalid
  rescue
    ArgumentError -> :invalid
  end
end
