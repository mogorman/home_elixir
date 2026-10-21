# `HomeElixir.Terminal`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/terminal.ex#L1)

Cowboy WebSocket handler that gives the browser a real IEx bridged over
xterm.js.

When the app itself is a named Erlang node (started with `--sname
home_elixir`, see README) the shell is `iex --remsh home_elixir` — a genuine
remote connection into this app's VM, with its code path, so `Node.list()`,
`HomeElixir.FlowStore.list()`, the HA client, etc. all see the live instance
 rather than a second app. `script` runs IEx in a pseudo-terminal so keystrokes
 echo and line editing work over the port.

If the app is NOT a named node, it falls back to a self-contained
`iex -S mix` (its own app instance) with `HOME_ELIXIR_NO_WEB=1` so it stays
off the parent's web port.

# `init`

# `terminate`

# `websocket_handle`

# `websocket_info`

# `websocket_init`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
