# `HomeElixir.Nodes.StateChanged`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/state_changed.ex#L1)

Source node: emits a message when a Home Assistant entity's state changes.

Config:
  * `entity_id` — optional; emit only for this entity. Omit for all entities.

The emitted message has `payload` = the new state, `topic` = the entity id,
and `data` = `%{entity_id:, old_state:, new_state:}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
