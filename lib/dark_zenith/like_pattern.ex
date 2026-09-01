defmodule DarkZenith.LikePattern do
  @moduledoc """
  Escaping for user input interpolated into `ILIKE` patterns (DESIGN.md: API
  Contract Details): `%`, `_`, and the escape character are literal in user
  input, never pattern syntax. Queries pair these patterns with
  `ESCAPE '\\'`.
  """

  @doc "The `%substring%` containment pattern with user input escaped."
  def contains(value) when is_binary(value), do: "%" <> escape(value) <> "%"

  @doc "Escapes `\\`, `%`, and `_` so they match literally."
  def escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
