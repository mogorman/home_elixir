# Changelog

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
