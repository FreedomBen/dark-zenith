defmodule DarkZenith.Repodata.XML do
  @moduledoc """
  Minimal deterministic XML encoding helpers. Every text and attribute value
  is escaped according to XML rules — never interpolated as raw markup.
  """

  @doc "Escapes a string for use in XML text content or attribute values."
  def escape(value) when is_binary(value) do
    for <<char <- value>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&#39;"
        _ -> <<char>>
      end
    end
  end

  def escape(value) when is_integer(value), do: Integer.to_string(value)

  @doc "The standard XML declaration line."
  def declaration, do: ~s(<?xml version="1.0" encoding="UTF-8"?>\n)
end
