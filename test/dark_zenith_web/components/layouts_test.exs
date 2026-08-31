defmodule DarkZenithWeb.LayoutsTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.Component
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

  describe "app/1" do
    test "maps widths to the spec's max widths and vertical rhythm" do
      for {width, class} <- [data: "max-w-7xl", prose: "max-w-3xl", narrow: "max-w-md"] do
        assigns = %{width: width}

        html =
          rendered_to_string(~H"""
          <Layouts.app flash={%{}} width={@width}>content</Layouts.app>
          """)

        assert html =~ class
        assert html =~ "py-8"
        assert html =~ "space-y-8"
      end
    end

    test "defaults to the prose width" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={%{}}>content</Layouts.app>
        """)

      assert html =~ "max-w-3xl"
    end
  end

  describe "breadcrumbs/1" do
    test "renders mono segments, muted separators, and an unlinked current segment" do
      assigns = %{
        segments: [
          {"Repositories", "/repos"},
          {"tools", "/repos/tools"},
          {"htop-3.4.1-1.fc44.x86_64", nil}
        ]
      }

      html =
        rendered_to_string(~H"""
        <Layouts.breadcrumbs segments={@segments} />
        """)

      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ "font-mono"
      assert html =~ ~s(href="/repos")
      assert html =~ ~s(href="/repos/tools")
      assert html =~ ~s(aria-current="page")
      refute html =~ ~r|<a[^>]*>\s*htop|
      assert length(Regex.scan(~r/aria-hidden/, html)) == 2
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
