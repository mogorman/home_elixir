# Changelog

## 0.1.85
- Rework: the API reference is now a normal in-app page (`/reference`) — the full module reference rendered from ExDoc's markdown, so it inherits the app's base handling, auth and navbar. Replaces the static `/static/docs` sub-site, which failed to load under some Home Assistant access paths.

## 0.1.84
- Fix: the API reference now opens **in the same panel** (not a new tab) when reached via Home Assistant's ingress, so it renders inside your logged-in session instead of hitting a 401. Browser-back returns to the app.

## 0.1.83
- Fix: the API reference (ExDoc) now works when the add-on is reached through Home Assistant's ingress. Each docs page is anchored to its own root with a `<base>`, so its links resolve under the ingress prefix instead of relying on the browser's URL.

## 0.1.82
- New **API** reference in the menu (and linked from Documentation): the full ExDoc module docs — every module, function and type, with search, like a published hex.pm package. Regenerated automatically on each release.

## 0.1.81
- Web console (IEx) no longer shows "connection closed" after sitting idle: the WebSocket now sends a periodic keepalive ping so the connection survives intermediate idle timeouts.

## 0.1.80
- New Documentation tab in the menu: an in-app copy of the HomeElixir docs (`/docs`), rendered from the bundled markdown with syntax-highlighted code blocks.

## 0.1.79
- Fix: the in-browser IEx now has working line editing (history, left/right, tab completion). The shell runs with no `TERM` in the container, which disabled IEx's line editor; it's now forced to `xterm-256color`.

## 0.1.78
- Flow editor: config options are now listed flow-scoped first, then global.

## 0.1.77
- mail_check example: the camera snapshot is now sent to the LLM as raw bytes via req_llm's `ContentPart.image` (req_llm base64-encodes it for the wire) instead of the app pre-building a base64 data URL; the snapshot still displays in the UI.

## 0.1.76
- The per-flow Node-RED indicator now turns green ("detected & working") when the Node-RED Companion is present, instead of only showing the yellow warning when it's missing. Applies to the flows-list badge and the note inside each flow's panel.

## 0.1.75
- Admin page now shows a green "Node-RED Companion: detected & working" note (with the detected version) when the integration is set up, instead of nothing. Re-checking now re-renders the card.

## 0.1.74
- Node-RED Companion detection now confirms the integration is actually added & set up (a config entry is loaded), not just that its files are installed. It probes the `nodered/version` websocket command — registered only once set up, alongside the `nodered/discovery`/`nodered/entity` commands device nodes use — so an installed-but-not-added integration is correctly reported as missing.

## 0.1.73
- Fix: Node-RED Companion detection now works — it checks for the `nodered` component (the old `node_red` service check never matched, so an installed integration was reported as missing).
- The Node-RED notice and admin card now explain the integration must be added & enabled under Settings → Devices & Services after the HACS install.

## 0.1.72
- Dark mode: secondary/outline buttons (Reset password, Re-check, dialog Cancel/Close) now show blue text on hover instead of grey-on-grey.

## 0.1.71
- Node-RED Companion notice is now anchored under the sticky menu with even spacing, and dismisses permanently ("Ignore permanently").
- Per-flow Node-RED warnings on the flows list are bold, and the same warning now shows inside the flow's panel.
- The "load flow without Node-RED" confirm dialog (and all dialogs) now respect the light/dark theme.
- Controls page: state badges and buttons are vertically centered.

## 0.1.70
- Node-RED Companion awareness: on startup the app detects whether the Node-RED Companion integration is installed in Home Assistant.
  - When it's missing, a dismissible notice under the menu explains it's optional and links the HACS install.
  - Flows that use Node-RED device nodes are flagged in the flows list; enabling one without the companion asks for confirmation (it still loads — only its device is affected).
  - Device nodes skip registering with Home Assistant when the companion is absent (logged once), and the flow→HA switch sync is paused.
  - The Admin page shows the companion status with a manual "Re-check" button while it's absent or unknown.

## 0.1.69
- Branding: the UI now reads "HomeElixir" (nav, page titles, login) instead of "home_elixir".

## 0.1.68
- The menu bar is now sticky — it stays pinned to the top of the page while you scroll.

## 0.1.67
- App bar height now matches HA's 56px top bar, so the panel aligns with the sidebar menu notch.
- Flows list: the enabled toggle is left-aligned to match the name/status/last-triggered columns.
- State badges are colored by value — green for on/true, red for off/false, grey for unknown/unavailable/error — with an optional flow-settable color.
- Device-history (table) UI now renders on the flows panel, not just the controls page.
- Config: masked secret values (tokens, passwords) no longer trigger the browser's "save password" prompt.
- Behind HA ingress the now-useless "Log out" button is hidden.
- Dark mode: nav menu hover uses the HA accent color instead of grey.
- Flows panel: the controls box sizes to its content (capped) and the logs box fills the rest.
- README/examples: the Android live-notification note now links to the workaround.

## 0.1.66
- Fixed the mobile menu (hamburger) dropping under the title when expanded — it now stays at the far right.
- Flows list: the old "actions" column is split into an "enabled" switch column and a separate "actions" (⋮) column.
- Add-on now ships an AppArmor profile (`apparmor.txt`) for full AppArmor confinement and the top add-on security rating.
- README: added the "Add to Home Assistant" install badge and a note that the Android companion's live-notification icon support is currently broken.

## 0.1.65
- Fixed the load/unload switch knob disappearing in the off state.
- Mobile menu (hamburger) now sits at the right of the app bar.
- Restored the Material Design icon font — the theme toggle and row/folder icons were rendering blank.
- Editor: Ctrl/Cmd+S saves the flow.

## 0.1.64
- Web UI drops Bootstrap in favor of Home Assistant's own design tokens plus an HA-styled component layer — colors, spacing, corner radii, shadows, and typography now match HA, and the accent follows HA's palette.

## 0.1.63
- Live Activities now actually reach the phone: fixed the notification service name and payload shape (companion fields in `data`) that were silently failing — the GPU alert's Live Activity works end-to-end.
- New "LiveUpdate" example: test Live Activities directly with trigger/+10/clear and toggles for every documented field (sticky, alert once, silent, chronometer, color, all-fields).
- "Save" no longer forces a page reload when the flow is already running.
- Fixed a duplicate loading spinner during dependency downloads.

## 0.1.62
- GpuUsageAlert: adds an Android/iOS Live Activity (companion) with a progress bar that fills 1% per alert and a count-up timer, via the new core `HomeElixir.HA.LiveUpdate`.

## 0.1.61
- Now ships for ARM (aarch64) as well as amd64.
- Menu order: Flows, Controls, Archived, Examples.

## 0.1.60
- Dep progress indicator moved to the header bar as plain text.

## 0.1.59
- Live progress indicator while flow dependencies install and compile.

## 0.1.58
- Example flow view shows only a Copy button.
- Config seeding no longer overwrites values that already exist.
- Config page per-key button renamed to Delete.

## 0.1.57
- Bundled examples moved to a separate Examples tab: view read-only, copy into your flows.
