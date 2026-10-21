# `HomeElixir.HA.Client`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/client.ex#L1)

A client for the Home Assistant WebSocket API.

Maintains a single authenticated WebSocket connection (through a transport,
default `HomeElixir.HA.Transport.Mint`), and offers:

  * `call/3` — id-correlated request/response
  * `subscribe_events/3` — HA event fan-out to a process
  * automatic reconnection (and re-auth + re-subscribe) after a drop

A transport is a GenServer following a small convention: it is started with
`module.start_link(owner: pid, url: url, token: token)`, sends
`{:ha_transport, :connected}`, `{:ha_transport, :text, binary}` and
`{:ha_transport, :closed, reason}` to its owner, and handles
`GenServer.cast(transport, {:ha_send, json})` to send an outbound frame.

# `call`

Send a request and await its correlated result.

Returns the `result` field on success (may be `nil`), or
`{:error, %{code: code, message: message}}` when Home Assistant reports an
error. Returns `{:error, {:not_connected, status}}` if not yet connected.

# `channels_for`

The current `[{id, node_id}]` for every channel discovered by `to` (the `node_id`
is read from each discovery frame).

Re-derive this rather than trusting the `id` returned by `discover/3`: a
reconnect's re-discovery reassigns a fresh id to each channel, so a cached
id→thing map goes stale and inbound frames on the new ids are dropped.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `discover`

Register a message-id channel for a long-lived HA feature (e.g. a Node-RED
device). A fresh id from the shared monotonically-increasing counter (the same
one `call/3` uses, so HA's "ids must increase" rule holds) is injected into
`discovery_frame`'s `"id"`; frames arriving with that id are forwarded to `to`
as `{:ha_channel, id, frame}`. The frame is sent now if connected and re-sent
on every (re)connect, so the entity re-establishes after a dropped connection.
Returns the channel `id` (so the caller can route inbound channel frames).

# `fire`

Send a request and ignore its response (fire-and-forget).

Use for `call_service` and similar, where the caller does not need HA's ack.
Returns `:ok` (the request is dropped if not connected).

# `start_link`

# `status`

Current connection status: `:connecting`, `:authenticating`, `:connected` or `:disconnected`.

# `subscribe_events`

Subscribe to Home Assistant events. Matching events are sent to `to` as
`{:ha_event, ref, event}`. Returns the subscription `ref`.

The subscription is registered immediately; if not yet connected it is sent
automatically on (re)connect, so callers need not wait for a connection.

# `token`

The access token this client authenticates with.

# `transport_pid`

The pid of the active transport (for diagnostics/tests); `nil` when down.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
