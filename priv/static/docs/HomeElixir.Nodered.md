# `HomeElixir.Nodered`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodered.ex#L1)

Helpers for managing Node-RED-integration entities from Elixir.

# `remove`

Force-remove a device previously presented via `HomeElixir.Nodes.Device`.

Sends a `nodered/discovery` frame with `remove: true`, deleting the entity
from Home Assistant. Use after unloading a flow (or to clean up a leftover
device) — unloading a flow leaves the entity in place (it goes unavailable
when this service's connection drops).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
