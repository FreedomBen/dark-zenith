defmodule DarkZenithWeb.FaviconAssetsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the favicon set specified in docs/DESIGN_UI.md (Identity — Favicon):
  the reticle on a Night-navy rounded square, shipped as SVG + ICO +
  apple-touch-icon.
  """

  @static Path.expand("../../priv/static", __DIR__)

  test "favicon.svg draws the reticle in the night palette" do
    svg = File.read!(Path.join(@static, "favicon.svg"))

    assert svg =~ "#0F1524", "missing the Night-navy ground"
    assert svg =~ "#E3B341", "missing the Zenith Gold star"
    assert svg =~ "#E8ECF4", "missing the Starlight ring"
  end

  test "favicon.ico is a real ICO carrying multiple sizes" do
    <<0, 0, 1, 0, count::little-16, _::binary>> = File.read!(Path.join(@static, "favicon.ico"))

    assert count >= 2
  end

  test "apple-touch-icon.png is a 180x180 PNG" do
    <<0x89, "PNG\r\n", 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>> =
      File.read!(Path.join(@static, "apple-touch-icon.png"))

    assert {w, h} == {180, 180}
  end
end
