# `HomeElixir.NodeRedStatus`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/node_red_status.ex#L1)

Tracks whether the Node-RED Companion integration is installed in Home
Assistant. Probed once at startup (and re-checkable on demand from the admin
page).

Status is three-state:

  * `:loaded` — the integration is added & set up (its `nodered/version`
    websocket command is registered, which only happens once a config entry
    is loaded)
  * `:absent` — HA is reachable but the integration is not added/set up
  * `:unknown` — can't tell (no HA client, not connected yet, or a probe error)

Only `:absent` changes behavior (the flow→Node-RED sync stops and `device`
nodes go inert). `:unknown` keeps existing behavior so a slow or absent HA
connection at boot never raises a false "missing" warning.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `present?`

True when the Node-RED integration is present.

# `recheck`

Re-run the probe now and return the new status.

# `start_link`

# `status`

Current status: `:loaded`, `:absent`, or `:unknown`.

# `version`

The detected integration version, when present (`nil` otherwise).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
