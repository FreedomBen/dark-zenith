defmodule DarkZenith.Rpm do
  @moduledoc """
  Pure-Elixir RPM v4/v6 metadata parser (DESIGN.md: RPM Parsing).

  Reads the lead, signature header, and main header — never the payload —
  and returns validated `%DarkZenith.Rpm.Metadata{}`. Integrity verification
  is deliberately delegated to RPM 6 `rpmkeys` in the upload pipeline; this
  module never checks or produces signatures.
  """

  alias DarkZenith.Rpm.{Extractor, Metadata, Parser}

  @doc """
  Parses a complete RPM file binary into extracted metadata.

  Returns `{:ok, %Metadata{}}` or `{:error, reason}`; every rejection maps
  to `422 validation_failed` in the upload pipeline.
  """
  @spec parse(binary()) :: {:ok, Metadata.t()} | {:error, atom()}
  def parse(binary) when is_binary(binary) do
    with {:ok, parsed} <- Parser.parse(binary) do
      Extractor.extract(parsed)
    end
  end
end
