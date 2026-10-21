# `HomeElixir.HA.Transport.Mint`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/transport/mint.ex#L1)

WebSocket transport backed by Mint + Mint.WebSocket.

Implements the transport convention expected by `HomeElixir.HA.Client`:
started with `start_link/1` (`owner:`, `url:`), reports
`{:ha_transport, :connected | :text, binary | :closed, reason}` to its owner,
and sends outbound frames given via `GenServer.cast(transport, {:ha_send, json})`.

The process owns an active-mode Mint connection, so inbound TCP/SSL data
arrives here as messages.

Validated against a live Home Assistant over `wss://` (connect, auth, and a
`get_states` round-trip). `mix run scripts/ha_validate.exs` reproduces it.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
