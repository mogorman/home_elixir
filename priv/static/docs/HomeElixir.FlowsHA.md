# `HomeElixir.FlowsHA`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/flows_ha.ex#L1)

Exposes every flow as a switch in a single "Flows" device in Home Assistant,
via the Node-RED Companion integration. Each switch's state is the flow's
loaded state; toggling it in HA loads/unloads the flow.

On every sync (at boot, after any create/delete/archive/restore, and on a
timer) the Flows device is reconciled against the live flow set: HA entities
with no matching non-archived flow are removed, and switches for current flows
are (re)discovered. The device's current switches are read from HA's REST
`/api/states` (the reliable source — the WS `get_states` list does not return
these entities), so orphaned entities are cleaned up even if they predate this
process's memory of them.

A no-op when HA is not configured.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `flow_switch_ids`

Pure: the Flows-device switch node_ids present in a `/api/states` list. HA names
them `switch.flows_<node_id>`, so the node_id is the suffix after that prefix;
any other entity (other devices, other domains) is ignored.

# `node_id`

The switch node_id for a flow name (`/` → `_`, downcased).

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
