defmodule DarkZenithWeb.FontAssetsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the self-hosted font setup specified in docs/DESIGN_UI.md (Typography):
  every face the stylesheet declares must ship in priv/static/fonts, alongside
  the OFL license texts, and the declared faces must cover the spec's weights.
  """

  @fonts_css Path.expand("../../assets/css/fonts.css", __DIR__)
  @fonts_dir Path.expand("../../priv/static/fonts", __DIR__)

  @spec_faces [
    {"Spectral", 500},
    {"Spectral", 600},
    {"IBM Plex Sans", 400},
    {"IBM Plex Sans", 500},
    {"IBM Plex Sans", 600},
    {"IBM Plex Mono", 400},
    {"IBM Plex Mono", 500}
  ]

  test "every font file referenced in fonts.css exists in priv/static/fonts" do
    refs =
      Regex.scan(~r|url\("/fonts/([^"]+)"\)|, File.read!(@fonts_css), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert refs != [], "fonts.css references no /fonts/ files"

    for file <- refs do
      assert File.exists?(Path.join(@fonts_dir, file)), "missing font file: #{file}"
    end
  end

  test "fonts.css declares every face and weight the UI design specifies" do
    declared =
      @fonts_css
      |> File.read!()
      |> String.split("@font-face", trim: true)
      |> Enum.flat_map(fn block ->
        with [_, family] <- Regex.run(~r/font-family:\s*"([^"]+)"/, block),
             [_, weight] <- Regex.run(~r/font-weight:\s*(\d+)/, block) do
          [{family, String.to_integer(weight)}]
        else
          _ -> []
        end
      end)

    for face <- @spec_faces do
      assert face in declared, "fonts.css is missing #{inspect(face)}"
    end
  end

  test "OFL license texts ship alongside the font files" do
    for license <- ["OFL-Spectral.txt", "OFL-IBM-Plex-Sans.txt", "OFL-IBM-Plex-Mono.txt"] do
      assert File.exists?(Path.join(@fonts_dir, license)), "missing license: #{license}"
    end
  end
end
