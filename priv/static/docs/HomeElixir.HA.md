# `HomeElixir.HA`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha.ex#L1)

Access to the shared, named `HomeElixir.HA.Client`.

Home Assistant uses a single WebSocket connection shared by every HA-aware
node (mirroring Node-RED). The app starts one named client when
`HA_URL`/`HA_TOKEN` are configured; nodes reach it through this module.

# `activate`

Store `token` as the shared HA auth (beats the static config until the next
login) and make sure the shared WS client runs with the current token
(start it when absent, restart it when it holds a different one). Called on
a successful web login.

# `build_range`

Resolve a history `range` to a `{start_iso, end_iso}` UTC pair. `nil` is the
last hour; a number is a look-back in hours; `{start, end}` is explicit
(DateTime or ISO8601). `now` (unix seconds) is injectable for tests.

# `client`

The pid of the shared client, or `nil` if it is not running.

# `client_name`

The atom name of the shared client process.

# `config_url`

The configured HA endpoint (env `HA_URL` or config `:ha_url`), or `nil`.

# `connected?`

True when a shared client is running.

# `device_entity_ids`

The `entity_id`s belonging to `device_id`, from an entity-registry list.

# `device_history`

State history for every entity on `device_id` over `range` (see `history/2`).
Returns `{:ok, [state_map]}` or `{:error, reason}`.

# `device_states`

The current states of every entity on `device_id` (resolved via the entity
registry), in registry order. Returns `{:ok, [state_map]}` or `{:error, reason}`.

# `ensure_client`

Ensure the shared WS client is running with the current token.

# `filter_states`

The states for `entity_ids` (in that order), from a `get_states` list.

# `find_state`

Find one entity's state in a `get_states` list, or `nil`.

# `flatten_history`

Flatten HA's history response (a list of per-entity lists) to one list.

# `history`

State history for `ids` (an entity_id or a list of them) over `range`.
`range` is `nil` (last hour), a number (look back N hours), or `{start, end}`
(DateTime or ISO8601 strings). Returns `{:ok, [state_map]}` (a flat list) or
`{:error, reason}`.

# `rest_base`

The HA REST base URL (`scheme://host[:port][/prefix]`) for HTTP API calls,
derived from the configured endpoint (which may be a `wss://`/`ws://`
WebSocket URL). Keeps any proxy path prefix: `ws://supervisor/core/api/websocket`
becomes `http://supervisor/core`, so callers append `/api/...` as usual.
`nil` when no HA endpoint is configured.

# `rest_prefix`

The REST path prefix implied by the configured endpoint (`"/core"` for the
supervisor Core proxy, `""` for a direct Core URL), or `nil` when no endpoint
is configured.

# `snapshot`

Fetch a camera snapshot for `entity_id` as raw bytes, via HA's
`/api/camera_proxy/{entity}` REST endpoint, over Mint (a core dependency, so
callers don't need to install `req`). Returns `{:ok, binary}` or
`{:error, reason}`.

# `snapshot_b64`

Fetch a camera snapshot for `entity_id` and return it base64-encoded (for
inlining as a `data:image/jpeg;base64,...` URL). Built on `snapshot/1`.
Returns `{:ok, base64}` or `{:error, reason}`.

# `state`

The current state of one entity (a `get_states` entry: `%{"entity_id",
"state", "attributes", "last_changed", "last_updated"}`), or `{:error, reason}`.

# `token`

The HA auth token used for all HA API calls (the shared WS client and REST).
First match wins:

  1. env `SUPERVISOR_TOKEN` — present only when running as an HA add-on; the
     only token the supervisor's Core proxy accepts
  2. the token from the most recent web login (HA OAuth), stored in global
     config
  3. env `HA_TOKEN` (the NixOS module)
  4. config `:ha_token` (e.g. config/secret.exs)

`nil` when nothing is configured.

# `web_base_url`

The public web origin (config `:web_base_url`), or `nil`.

# `whoami`

Resolve who an HA access token belongs to via the WebSocket `auth/current_user`
command, on a transient one-shot client. Returns `{:ok, {name, is_admin}}` or
`{:error, reason}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
