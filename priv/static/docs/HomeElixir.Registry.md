# `HomeElixir.Registry`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/registry.ex#L1)

Loads and unloads flows and tracks which are running.

A *flow* is an Elixir module using `HomeElixir.Flow`. Loading it spawns a
supervised process per node and wires them together; unloading tears it down.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `list`

All currently loaded flow modules.

# `load`

Load a flow module. Returns `{:ok, pid}` or `{:error, reason}`.

# `loaded?`

Whether a flow module is loaded.

# `node_state`

Read a node's internal state (for tests / debug).

# `send_msg`

Cast a message into a node of a loaded flow.

# `start_link`

# `ui_elements`

UI elements declared by loaded flows. Collects nodes whose config has a
`ui:` map and returns `[%{module, node_id, ui}]`.

# `unload`

Unload a flow module (stops all its nodes).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
