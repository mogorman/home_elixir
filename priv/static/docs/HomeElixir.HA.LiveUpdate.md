# `HomeElixir.HA.LiveUpdate`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/live_update.ex#L1)

Send and dismiss Android/iOS Home Assistant companion **Live Activities** to a
person's devices — the reusable core. Flows just call `update/3` / `dismiss/2`.

A person's companion devices are discovered from their `person.<name>` entity's
`device_trackers` list; each `device_tracker.<slug>` maps to the notify service
`mobile_app_<slug>` (the `notify` domain is added separately, so the service
name carries no `notify.` prefix).

The companion reads its Live Activity fields (`tag`, `live_update`, `progress`,
`progress_max`, `chronometer`, `when`, `notification_icon`, `color`, ...) from
the notify service's **`data`** dict; `title`/`message` stay top-level (HA's
schema requires them there). `update/3` adds a fixed `tag` and
`live_update: true` so a later call with the same tag updates the activity in
place; `dismiss/2` clears it by tag.

The dispatch is **fire-and-forget** (an async `cast` to the HA client), so a
caller never blocks waiting for delivery; only the single `get_states` read
that resolves a person's devices is a (bounded) blocking call. Android requires
Android 16+ for Live Activities to render.

# `dismiss`

Dismiss the Live Activity `tag` on every companion device of `person`.

# `update`

Send (or update) a Live Activity on every companion device of `person`.

`person` is a person name (`"mog"`) or full entity (`"person.mog"`); `tag` keys
the activity; `payload` holds the companion fields (`title`, `message`,
`progress`, `progress_max`, `chronometer`, `when`, `notification_icon`,
`color`, ...). Returns `{:ok, count}` (devices dispatched to) or `{:error,
reason}`: `:not_connected`, `:person_not_found`, `:no_devices`, or `:ha_timeout`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
