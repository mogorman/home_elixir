# Changelog

## 0.1.106
- **Fix: GPU usage alert example crashed on load with `:badarith` while a card was already hot.** `display/0` computed the elapsed time by subtracting from the wrong value — `Enum.min_by/2` returns the whole `{index, since}` element, not the `since`, so the arithmetic ran `now - {index, since}` and raised. It now extracts the `since` first. This is the real root cause behind the "stale tuple" reports; the persisted per-card value was always a plain integer, and the guard added in 0.1.103 is removed (the store only ever holds an integer or `nil` for these keys). **Re-copy the example from Examples** to pick up the fix.
- **Fix: a flow left in a broken (non-compiling) state could not be saved back to a working state.** The compiled-module cache recorded a compile error against the file's checksum but matched that error against *any* later checksum, so once a flow's compile failed the module was pinned to "none" and every reload kept returning `:compile_error`. The error is now pinned to the file checksum it came from, so editing the file (even just to fix it) triggers a fresh compile and the flow recovers.
- **UI:** the Controls / Flow-logs row on the flow editor now has the same top spacing as the Config panel (they were touching).

## 0.1.105
- **Flow-state is now self-cleaning across broken/renamed/out-of-band changes.** A flow's runtime state is keyed by its module, so a module that no longer exists (renamed `defmodule`, a flow whose file was deleted out-of-band, or a stale backup restore) used to leave its old records behind forever. The app now sweeps such "orphaned" records at lifecycle points — before load/reload/save, after unload/delete/rename, and at startup — keyed off the `defmodule` declared by each current flow file (parsed by regex, so it works even on a broken file). A flow's *own* state is never swept (its file declares it), so normal persistence across reloads/restarts is unchanged.
- **Fixed a crash when a flow fails to load:** the editor's "could not load" path called `to_string/1` on a nested error tuple, which itself raised `String.Chars not implemented for Tuple` and hid the real reason. It now uses `inspect/1`, so the actual load error (e.g. a `:badarith`) is shown.

## 0.1.104
- **Fix: deleting a flow no longer left its persisted state behind.** `FlowState` runtime (the per-flow `FlowState.put` values) is keyed by the flow's *module*, and delete only cleared the app-metadata record — so re-copying or re-creating a flow of the same module inherited its old state (the reason the GPU usage alert crash survived a delete + re-copy). Delete and rename now also clear the flow's runtime record, so a re-created flow starts fresh.

## 0.1.103
- **Fix: GPU usage alert crashed on load with `:badarith` (surfacing as `String.Chars not implemented for Tuple`) on installs that had run an older version.** The per-card "hot since" state is disk-backed and outlives the code, so a stale non-integer left by a prior version made the elapsed-time arithmetic blow up. The flow now sanitizes every persisted-since read (a non-integer is treated as "cooled"), so a flow that predates the integer-since format loads cleanly and self-heals on the next reading.

## 0.1.102
- **GPU usage alert example rewritten on the handle pattern** so it actually runs — the old version defined a flow-level `run/2`/`subscribe/1` protocol the engine never dispatched, so it could never fire. It now watches **all three** RTX 3090 cards at once via the auto-wired `state_changed` source, and a 1-minute tick re-evaluates so a card *pinned* at a constant high value (which emits no change events) still alerts once it has been hot long enough. The Live Activity chronometer now shows how long **any** card has been running hot (keyed to the earliest hot card), the progress bar fills 1% per alert, and the Signal message still fires on each alert. Threshold/sustain/cooldown/person/service are now editable in the flow config.

## 0.1.101
- **Editor config panel now works on phones.** On narrow screens each row stacks — the key, the value (a full-width text box when editing), and the action buttons each get their own line — and the Add row wraps, so nothing overflows horizontally. The desktop single-line layout is unchanged.

## 0.1.100
- **Editor config panel:** the row action buttons (Delete, and Save/show when editing) now sit in their own fixed, right-aligned column with a little breathing room from the value, so they stay put and don't float or wrap when a row switches into edit mode. Space is reserved up front for the full Save/show/Delete set, so the page never reflows.

## 0.1.99
- **Editor config panel redesigned** to be tighter and clearer. It now shows two sections — **Flow** (blue) and **Global** (grey) — and a section with no keys isn't rendered at all. Values display as plain labels; click a row to turn it into a text box with inline Save/Delete. A **shadowed** Flow value (one that also exists in Global) is tagged "overrides Global", and clicking it **unshadows** it (drops the flow override so it falls back to the global value). Secret values stay masked and gain a show/hide toggle.

## 0.1.98
- **Editor:** added spacing between the flow editor and the Config panel below it (they were touching).

## 0.1.97
- **Laundry example** now attributes the "it's done" message to who **started** the cycle, not who happens to be on the camera when it finishes. On start (the `*_run_state` sensor flipping to the running value, config `running_state`, default `Running`) it captures the last basement-cam face and stores it as the starter (per machine); on finish it notifies that person, falling back to the current face if it never saw a start.

## 0.1.96
- **Fix: "Download all → Zip" failed** (501) while tar/json worked. The release image's OTP (29) ships a `:zip` with only `create` and no read API, so the zip-availability check (which also required the read functions) wrongly disabled zip export. Downloading a zip now only requires `:zip.create`, so it works; zip *import* still needs the read API and is unaffected (use tar/json to import zips on such builds).

## 0.1.95
- **Fix: downloads failing with 503 behind a reverse proxy.** The download endpoints no longer send a `Content-Disposition: attachment` header (which the Caddy→HA proxy chain drops with a 503); they return a small JSON envelope and the browser builds the file client-side. Applies to single-flow download, Download-all (zip/tar/json), and Backup.
- Fixed unreadable buttons in **dark mode** (e.g. the Cancel/Delete-dialog buttons rendered near-white on near-white).
- Removed the top-nav **API** link — the API reference is still reachable from Documentation.
- Consolidated the progress indicators into a single spinner next to the username (dependency-install progress now uses it instead of a separate banner).

## 0.1.94
- Full-state **Backup / Restore** (admin only, in the flows list header). **Backup** downloads a single `home-elixir-backup.json` capturing everything the app persists — flow source files, config (global + per-flow), user accounts (with password hashes), and flow state (ownership/metadata + per-flow live runtime). **Restore** uploads the same file to put it back (non-destructive: overwrites what's present, leaves absent keys alone, so it doubles as a partial import). New endpoints `GET /api/backup` and `POST /api/restore`. Config and per-flow runtime carry arbitrary terms as lossless base64 blobs; the rest is plain JSON.

## 0.1.93
- Flow import/export now supports **zip**, **tar**, and **json** bundles. "Download all" is a format picker (Zip / Tar / JSON); Upload accepts a single `.ex`, a `home-elixir-flows.json`, or a `.zip`/`.tar` (also `.tar.gz`) of flows. `GET /api/flows/download-all?format=zip|tar|json` and `POST /api/flows/import` (with an `x-bundle-format` header) back it. Zip uses OTP's `:zip` (in the release image); tar uses the system `tar`; json is pure Elixir. Per-flow ownership rules still apply on import.

## 0.1.92
- Flow import/export in the web UI: **Download** a single flow (per-flow menu), **Download all** of your visible flows as a JSON bundle (`home-elixir-flows.json`), and **Upload** — either a single `.ex` file (saved like the editor) or the JSON bundle to import several at once. New endpoints `GET /api/flows/<name>/download`, `GET /api/flows/download-all`, and `POST /api/flows/import` (per-flow ownership rules apply; imported flows are written, not auto-loaded).

## 0.1.91
- Moved the **Laundry** flow (0.1.90) from `flows/` to `examples/laundry.ex` — it's a ready-to-copy example, not a bundled default.

## 0.1.90
- New **Laundry** flow (`flows/laundry.ex`): when an LG ThinQ washer or dryer finishes a cycle (its `run_completed` sensor flips to `on`), it raises a companion **Live Activity** and a **Signal** message, attributed to the last face the basement Frigate camera recognized — e.g. "matthias finished the washing". Person, Signal service, and face sensor are editable in the flow config; covered by tests.

## 0.1.89
- Chores (no behavior change): de-duplicated internals — a shared Mint REST helper replaces a second hand-rolled HTTP stack in the Flows-HA sync, one shared Mnesia/CA-cert helper replaces per-module copies, ISO-8601 timestamps now use the stdlib, and a couple of test-only APIs were removed.

## 0.1.88
- Fix: external "Log in with Home Assistant" now works alongside the embedded panel. The OAuth token's identity is validated against your real HA core (`ha_external_url`) instead of the Supervisor proxy (which only accepts `SUPERVISOR_TOKEN`), so login succeeds and the add-on's Supervisor connection stays intact.

## 0.1.87
- Added `HomeElixir.HA.entity_history/2` — single-entity state history, named to mirror `device_history/2` (the EntityHistory example now uses it; `history/2` remains for lists).

## 0.1.86
- Added cross-links between the Documentation (user guide) and API reference pages.

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
