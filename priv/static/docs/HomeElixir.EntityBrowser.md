# `HomeElixir.EntityBrowser`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/entity_browser.ex#L1)

Build an Area > Device > Entity tree of Home Assistant entities, for the
editor's entity browser. `build/3` is pure and assembles the tree from three
read-only HA lists; `tree/0` fetches them from the shared HA client.

Areas come from each device's `area_id` (there is no reliable "list areas"
command across HA versions), so area labels are the prettified area slug.

# `build`

Pure: build the Area > Device > Entity tree from three HA lists.

`states` (`get_states`), `registry` (`config/entity_registry/list`),
`devices` (`config/device_registry/list`). An entity's area is its own
`area_id`, else its device's; with no area it goes under `"No area"`. Entities
with no device are listed loose under their area; a `device_id` not in
`devices` is named `"Unnamed device"`. Returns a list of
`%{"name", "devices" => [%{"name", "entities"}], "entities"}` maps, each
entity a `%{"id", "name", "state", "unit", "cls"}` map.

# `tree`

Fetch and build the tree. `connected: false` when no HA client is running.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
