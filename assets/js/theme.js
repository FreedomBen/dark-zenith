// Pre-paint theme selection (docs/DESIGN_UI.md — Theme behavior).
//
// Loaded as an external parser-blocking script in <head>: the app's CSP is
// script-src 'self' with no unsafe-inline, so this cannot live inline, and it
// must run before first paint to avoid a flash of the wrong theme.
//
// Dark is the unforced default for first-time visitors; explicit choices —
// including "system" — are stored, since key absence now means "never chose".
(() => {
  const systemTheme = () =>
    matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"

  const applyTheme = (theme, source) => {
    document.documentElement.setAttribute("data-theme", theme === "system" ? systemTheme() : theme)
    document.documentElement.setAttribute("data-theme-source", source)
  }

  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.setItem("phx:theme", "system")
      applyTheme("system", "system")
    } else {
      localStorage.setItem("phx:theme", theme)
      applyTheme(theme, "user")
    }
  }

  if (!document.documentElement.hasAttribute("data-theme")) {
    const stored = localStorage.getItem("phx:theme")
    stored ? setTheme(stored) : applyTheme("dark", "default")
  }

  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "dark"))
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme))

  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (document.documentElement.getAttribute("data-theme-source") === "system") {
      document.documentElement.setAttribute("data-theme", systemTheme())
    }
  })
})()
