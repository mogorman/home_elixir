# `HomeElixir.Nodes.Device`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/device.ex#L1)

Presents a device (entity) to Home Assistant via the Node-RED integration and
owns its state bidirectionally.

On load it registers the device with HA (`nodered/discovery`) and keeps a
channel on that message id. When the entity is toggled in the HA frontend, HA
pushes a frame back on that id; this node echoes the state back so the entity
sticks, then emits it into the flow (source). When a message arrives (e.g. from
a web button), it sets the entity's state via `nodered/entity` (sink). The node
also tracks its current state, so a `ui: %{type: "state"}` element can display it.

Config:
  * `server_id`, `node_id` — identify the device (required, unique per device)
  * `component` — `"switch"` (also `sensor`/`button`/`binary_sensor`), default `"switch"`
  * `config` — entity display: `name`, `icon`, `device_class`, ...
  * `device_info` — device grouping: `id`, `name`, `manufacturer`, ...
  * `state` — initial state; also the reset-to-default target
  * `inherit` — `true` to adopt the entity's current HA state on load (default `false`)

Inbound messages set the state from `payload` (a bare value, or a map with a
`"state"`/`:state` key). A `payload` of `%{reset: true}` (or `{:reset, _}`)
resets to the flow-declared `state`.

Use `HomeElixir.Nodered.remove/2` to force-delete the entity.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
