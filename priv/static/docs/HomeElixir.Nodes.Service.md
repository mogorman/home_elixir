# `HomeElixir.Nodes.Service`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/service.ex#L1)

Sink node: calls a Home Assistant service when a message arrives.

Config:
 * `domain` — e.g. `"light"` (required)
 * `service` — e.g. `"turn_on"` (required)
 * `data` — optional static `service_data` map; a map `payload` on the
   incoming message is merged in (message wins)

The call is sent and its ack awaited, ensuring the service is reliably
delivered over the WebSocket (a fire-and-forget cast proved lossy).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
