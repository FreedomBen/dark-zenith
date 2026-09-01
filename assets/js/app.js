// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dark_zenith"

// Direct-to-B2 upload (DESIGN.md: Upload RPM). The selected File goes
// straight to the presigned URL; the user agent supplies the signed
// Content-Length, and the CORS-exposed x-amz-version-id header completes
// the intent. RPM bytes never touch Phoenix.
const DirectUpload = {
  mounted() {
    // The hook lives on a wrapper that stays mounted across phases, so
    // listeners are delegated: the file input and drop zone only exist in
    // the idle phase and are re-rendered on reset.
    const select = file => {
      if (!file) return
      this.file = file
      this.pushEvent("select_file", {name: file.name, size: file.size})
    }
    const zone = () => this.el.querySelector("[data-drop-zone]")
    this.el.addEventListener("change", e => {
      if (e.target.matches("input[type=file]")) select(e.target.files[0])
    })
    // Drag-and-drop onto the zone (docs/DESIGN_UI.md — Upload). The depth
    // counter keeps the highlight through dragenter/dragleave on children.
    this.dragDepth = 0
    this.el.addEventListener("dragenter", e => {
      const z = zone()
      if (!z) return
      e.preventDefault()
      this.dragDepth++
      z.classList.add("dz-dragover")
    })
    this.el.addEventListener("dragover", e => zone() && e.preventDefault())
    this.el.addEventListener("dragleave", () => {
      this.dragDepth = Math.max(this.dragDepth - 1, 0)
      if (this.dragDepth === 0) zone()?.classList.remove("dz-dragover")
    })
    this.el.addEventListener("drop", e => {
      const z = zone()
      if (!z) return
      e.preventDefault()
      this.dragDepth = 0
      z.classList.remove("dz-dragover")
      select(e.dataTransfer.files[0])
    })
    this.handleEvent("start_upload", ({url}) => this.put(url))
  },
  async put(url) {
    try {
      const resp = await fetch(url, {
        method: "PUT",
        headers: {"Content-Type": "application/x-rpm"},
        body: this.file,
      })
      if (resp.ok) {
        const versionId = resp.headers.get("x-amz-version-id")
        if (versionId) {
          this.pushEvent("uploaded", {version_id: versionId})
          return
        }
      }
      this.pushEvent("upload_failed", {status: resp.status})
    } catch (_error) {
      this.pushEvent("upload_failed", {status: 0})
    }
  },
}
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DirectUpload},
})

// Command-block copy buttons (docs/DESIGN_UI.md — Components). The button
// dispatches dz:copy at its block; copy the <code> text and flash the
// checkmark by toggling dz-copied. The textarea fallback covers insecure
// contexts (plain-http LAN deployments) where navigator.clipboard is absent.
window.addEventListener("dz:copy", event => {
  const block = event.target
  const code = block.querySelector("code")
  if (!code) return
  const confirm = () => {
    block.classList.add("dz-copied")
    setTimeout(() => block.classList.remove("dz-copied"), 2000)
  }
  if (navigator.clipboard) {
    navigator.clipboard.writeText(code.innerText).then(confirm, confirm)
  } else {
    const scratch = document.createElement("textarea")
    scratch.value = code.innerText
    scratch.style.position = "fixed"
    scratch.style.opacity = "0"
    document.body.appendChild(scratch)
    scratch.select()
    document.execCommand("copy")
    scratch.remove()
    confirm()
  }
})

// Global search focus shortcuts (docs/DESIGN_UI.md — App shell): "/" and
// Ctrl/Cmd+K focus the nav search field, ignored while typing in another
// field. Below md the field sits in a collapsed <details>, which must open
// before its input can take focus.
window.addEventListener("keydown", e => {
  const slash = e.key === "/" && !e.ctrlKey && !e.metaKey && !e.altKey
  const combo = e.key.toLowerCase() === "k" && (e.ctrlKey || e.metaKey) && !e.altKey
  if (!slash && !combo) return
  const t = e.target
  if (t instanceof HTMLElement &&
      (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName))) return
  // A closed <details> hides its content without display:none in Chrome, so
  // offsetParent alone cannot tell the collapsed field from the visible one.
  const inputs = [...document.querySelectorAll("[data-global-search]")]
  let input = inputs.find(el => el.offsetParent !== null && !el.closest("details:not([open])"))
  if (!input) {
    const collapsed = inputs.find(el => el.closest("details:not([open])"))
    if (!collapsed) return
    collapsed.closest("details").open = true
    input = collapsed
  }
  input.focus()
  e.preventDefault()
})

// Show progress bar on live navigation and form submits
// Zenith Gold (docs/DESIGN_UI.md — Color)
topbar.config({barColors: {0: "#E3B341"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

