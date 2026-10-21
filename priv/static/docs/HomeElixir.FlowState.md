# `HomeElixir.FlowState`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/flow_state.ex#L1)

Persistent per-flow state, namespaced by the calling flow's module.

Call these from a flow's `handle/1`, a node transform, or `setup/0` — no module
argument needed. The current flow is taken from the ambient context (the node
process running the code), so two flows using the same key can't stomp on each
other's state:

     HomeElixir.FlowState.update(:count, &(&1 + 1))
     HomeElixir.FlowState.get(:last_entity)
     HomeElixir.FlowState.delete(:last_entity)

  Backed by a Mnesia table — on disk by default (survives restarts; needs the
  app to run as a named node), in-memory when `:flow_state_disc` is false or
  the node is nonode@nohost — so state survives flow reloads and restarts.
  Started by `HomeElixir.Application`.

From outside a node (tests, scripts), target a flow explicitly with `as/2`:

    HomeElixir.FlowState.as(MyFlow, fn -> HomeElixir.FlowState.get(:count) end)

# `all_flow_owners`

# `all_last_triggered`

# `archive`

# `archived_names`

# `as`

# `assign_owner_if_new`

# `clear_flow_owner`

# `current_flow`

# `delete`

# `ever_loaded_names`

# `flow_owner`

# `forget_flow`

# `forget_triggered`

# `get`

# `is_archived?`

# `last_triggered`

# `loaded_checksums`

# `loaded_names`

# `loaded_source`

# `owned_flow_names`

# `public_owner`

# `put`

# `record_load`

# `record_triggered`

# `save_loaded_names`

# `set_flow`

# `set_flow_owner`

# `start`

# `stop`

# `unarchive`

# `update`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
