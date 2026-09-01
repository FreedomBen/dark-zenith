defmodule DarkZenithWeb.ThemeContrastTest do
  use ExUnit.Case, async: true

  @moduledoc """
  WCAG AA verification for both themes (docs/DESIGN_UI.md — Color;
  Accessibility & motion; rollout item U8): ≥ 4.5:1 for body-size text and
  ≥ 3:1 for large text and UI components, computed from the palette tokens
  in `assets/css/app.css` so palette edits cannot silently regress AA.

  Alpha-composited pairs mirror how muted text is actually rendered:
  Tailwind's `text-base-content/70` and the custom placeholder/border rules
  all resolve to the token at an alpha over a known ground, which browsers
  composite in sRGB.
  """

  @css_path Path.expand("../../assets/css/app.css", __DIR__)

  # The app's muted-text conventions (see the usage assertions below):
  # body-size muted text is base-content at 70%, placeholders at 65%, the
  # day hero subhead at 80%, and resting form-control borders at 40%
  # (night) / 50% (day).
  @muted_alpha 0.70
  @placeholder_alpha 0.65
  @hero_muted_alpha 0.80
  @field_border_alpha %{"dark" => 0.40, "light" => 0.50}

  setup_all do
    css = File.read!(@css_path)

    themes =
      ~r/@plugin "daisyui\/packages\/bundle\/daisyui-theme" \{([^}]*)\}/
      |> Regex.scan(css, capture: :all_but_first)
      |> Map.new(fn [block] ->
        [name] = Regex.run(~r/name: "(\w+)"/, block, capture: :all_but_first)

        colors =
          ~r/--color-([a-z0-9-]+): (#[0-9a-fA-F]{6})/
          |> Regex.scan(block, capture: :all_but_first)
          |> Map.new(fn [token, hex] -> {token, hex} end)

        {name, colors}
      end)

    assert Map.keys(themes) |> Enum.sort() == ["dark", "light"],
           "expected exactly the dark (night) and light (day) theme blocks"

    invariant =
      ~r/--color-(umbra|starlight): (#[0-9a-fA-F]{6})/
      |> Regex.scan(css, capture: :all_but_first)
      |> Map.new(fn [token, hex] -> {token, hex} end)

    assert map_size(invariant) == 2, "expected the umbra and starlight tokens in @theme"

    %{css: css, themes: themes, invariant: invariant}
  end

  describe "token pairs" do
    test "body text meets 4.5:1 in both themes", %{themes: themes} do
      for {theme, c} <- themes do
        # Page text on the three grounds.
        assert_contrast(theme, "base-content on base-100", c["base-content"], c["base-100"], 4.5)
        assert_contrast(theme, "base-content on base-200", c["base-content"], c["base-200"], 4.5)
        assert_contrast(theme, "base-content on base-300", c["base-content"], c["base-300"], 4.5)

        # Inline links (Vega / chart blue) on page and menu grounds.
        assert_contrast(theme, "accent links on base-100", c["accent"], c["base-100"], 4.5)
        assert_contrast(theme, "accent links on base-200", c["accent"], c["base-200"], 4.5)

        # Outline/soft badge and inline semantic text on the page ground.
        for token <- ~w(secondary info success warning error) do
          assert_contrast(theme, "#{token} text on base-100", c[token], c["base-100"], 4.5)
        end
      end
    end

    test "content-on-color pairs meet 4.5:1 in both themes", %{themes: themes} do
      for {theme, c} <- themes,
          token <- ~w(primary secondary accent neutral info success warning error) do
        assert_contrast(
          theme,
          "#{token}-content on #{token}",
          c["#{token}-content"],
          c[token],
          4.5
        )
      end
    end

    test "focus ring and active-nav gold meet 3:1 on every ground", %{themes: themes} do
      for {theme, c} <- themes, ground <- ~w(base-100 base-200 base-300) do
        assert_contrast(theme, "primary on #{ground}", c["primary"], c[ground], 3.0)
      end
    end

    test "the theme-invariant command block meets 4.5:1", %{invariant: i} do
      assert_contrast("both", "starlight on umbra", i["starlight"], i["umbra"], 4.5)

      # The eyebrow label and copy button render at starlight/60.
      eyebrow = composite(i["starlight"], 0.60, i["umbra"])
      assert_contrast("both", "starlight/60 on umbra", eyebrow, i["umbra"], 4.5)
    end
  end

  describe "composited usage pairs" do
    test "muted body text at 70% meets 4.5:1 on page and hover grounds", %{themes: themes} do
      for {theme, c} <- themes, ground <- ~w(base-100 base-200) do
        muted = composite(c["base-content"], @muted_alpha, c[ground])
        assert_contrast(theme, "base-content/70 on #{ground}", muted, c[ground], 4.5)
      end
    end

    test "placeholders at 65% meet 4.5:1", %{themes: themes} do
      for {theme, c} <- themes do
        placeholder = composite(c["base-content"], @placeholder_alpha, c["base-100"])
        assert_contrast(theme, "placeholder on base-100", placeholder, c["base-100"], 4.5)
      end
    end

    test "the hero subhead at 80% meets 4.5:1 on the day gradient top", %{
      css: css,
      themes: themes
    } do
      # The day hero deepens toward #cddef2 at the top (app.css .dz-hero);
      # the subhead must hold AA against the deepest stop it can sit on.
      assert css =~ "#cddef2", "expected the day hero gradient stop in app.css"

      day = themes["light"]
      subhead = composite(day["base-content"], @hero_muted_alpha, "#cddef2")
      assert_contrast("light", "hero subhead on gradient top", subhead, "#cddef2", 4.5)

      night = themes["dark"]
      assert css =~ "#0a0f1c", "expected the night hero gradient stop in app.css"
      night_subhead = composite(night["base-content"], @muted_alpha, "#0a0f1c")
      assert_contrast("dark", "hero subhead on gradient top", night_subhead, "#0a0f1c", 4.5)
    end

    test "resting form-control borders meet 3:1 on form grounds", %{themes: themes} do
      for {theme, c} <- themes, ground <- ~w(base-100 base-200) do
        border = composite(c["base-content"], @field_border_alpha[theme], c[ground])
        assert_contrast(theme, "field border on #{ground}", border, c[ground], 3.0)
      end
    end
  end

  describe "usage conventions" do
    test "no template text uses base-content below 70% opacity" do
      web_root = Path.expand("../../lib/dark_zenith_web", __DIR__)

      offenders =
        web_root
        |> Path.join("**/*.{ex,heex}")
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _index} ->
            # Decorative, aria-hidden glyphs (breadcrumb separators) may sit
            # below the AA floor; anything else at ≤ 60% fails 4.5:1 on Day.
            line =~ ~r{text-base-content/[1-6]0} and not (line =~ "aria-hidden")
          end)
          |> Enum.map(fn {_line, index} -> "#{Path.relative_to(file, web_root)}:#{index}" end)
        end)

      assert offenders == [],
             "muted text below base-content/70 fails AA on the day theme: #{inspect(offenders)}"
    end
  end

  describe "app.css declares the accessibility invariants" do
    test "a global Zenith Gold focus outline", %{css: css} do
      assert [rule] = Regex.run(~r/:focus-visible \{[^}]*\}/, css),
             "expected a global :focus-visible rule (docs/DESIGN_UI.md — Accessibility)"

      assert rule =~ "2px"
      assert rule =~ "var(--color-primary)"
      assert rule =~ "outline-offset"
    end

    test "a prefers-reduced-motion clamp", %{css: css} do
      assert css =~ "@media (prefers-reduced-motion: reduce)"
      assert css =~ "animation-iteration-count: 1"
    end

    test "the placeholder and field-border alpha rules match the tested values", %{css: css} do
      assert css =~ "--color-base-content) 65%",
             "expected the 65% placeholder rule tested above"

      assert css =~ "--color-base-content) 40%",
             "expected the 40% night field-border rule tested above"

      assert css =~ "--color-base-content) 50%",
             "expected the 50% day field-border rule tested above"
    end
  end

  ## WCAG math (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio)

  defp assert_contrast(theme, label, fg, bg, min) do
    ratio = contrast(fg, bg)

    assert ratio >= min,
           "#{theme}: #{label} is #{Float.round(ratio, 2)}:1, needs ≥ #{min}:1 " <>
             "(#{format(fg)} on #{format(bg)})"
  end

  defp contrast(fg, bg) do
    {l1, l2} = {luminance(fg), luminance(bg)}
    (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  end

  defp luminance(color) do
    {r, g, b} = rgb(color)

    [r, g, b]
    |> Enum.map(fn channel ->
      c = channel / 255
      if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [rl, gl, bl] -> 0.2126 * rl + 0.7152 * gl + 0.0722 * bl end)
  end

  # sRGB alpha compositing: how the browser flattens `color-mix(color X%,
  # transparent)` text and borders onto their ground.
  defp composite(fg, alpha, bg) do
    {fr, fg_, fb} = rgb(fg)
    {br, bg_, bb} = rgb(bg)

    {round(fr * alpha + br * (1 - alpha)), round(fg_ * alpha + bg_ * (1 - alpha)),
     round(fb * alpha + bb * (1 - alpha))}
  end

  defp rgb({_r, _g, _b} = parsed), do: parsed

  defp rgb("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp format({r, g, b}) do
    "#" <>
      Enum.map_join([r, g, b], fn c ->
        c |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)
  end

  defp format("#" <> _ = hex), do: hex
end
