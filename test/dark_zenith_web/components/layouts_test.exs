defmodule DarkZenithWeb.LayoutsTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DarkZenithWeb.Layouts

  describe "zenith_mark/1" do
    test "renders the reticle: ring and ticks in currentColor, star in the primary token" do
      svg = render_component(&Layouts.zenith_mark/1, %{})

      assert svg =~ ~s(viewBox="0 0 24 24")
      assert svg =~ ~s(stroke="currentColor")
      assert svg =~ ~s|fill="var(--color-primary)"|
      assert svg =~ ~s(aria-hidden="true")
    end

    test "accepts a sizing class" do
      assert render_component(&Layouts.zenith_mark/1, class: "size-4") =~ ~s(class="size-4")
    end
  end

  describe "app_footer/1" do
    test "shows the mark, app version, and license, and links to the source" do
      html = render_component(&Layouts.app_footer/1, %{})

      version = to_string(Application.spec(:dark_zenith, :vsn))
      assert html =~ "<svg"
      assert html =~ "Dark Zenith"
      assert html =~ "v#{version}"
      assert html =~ "AGPL-3.0-or-later"
      assert html =~ ~s(href="#{DarkZenith.source_url()}")
      assert html =~ "Source"
    end

    test "the Source link follows the source_url config (AGPL §13)" do
      original = Application.get_env(:dark_zenith, :source_url)
      on_exit(fn -> Application.put_env(:dark_zenith, :source_url, original) end)
      Application.put_env(:dark_zenith, :source_url, "https://example.com/my-fork")

      assert render_component(&Layouts.app_footer/1, %{}) =~
               ~s(href="https://example.com/my-fork")
    end
  end

  # Kept in this module (not async elsewhere) so the override test above cannot
  # race a concurrent read of the default.
  test "source_url/0 defaults to the upstream project repository" do
    assert DarkZenith.source_url() == "https://github.com/FreedomBen/dark-zenith"
  end
end
