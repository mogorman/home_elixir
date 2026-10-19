# Changelog

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
