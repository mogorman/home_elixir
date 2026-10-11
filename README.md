# HomeElixir

A Node-RED-style flow engine for Home Assistant in Elixir. Flows are plain `.ex`
files in `flows/`; the app connects to Home Assistant over its WebSocket API and
runs the flows as an OTP supervision tree.

## Running

Start the app and its web UI (flow list, editor, live logs):

```sh
HA_URL=wss://... HA_TOKEN=... mix run --no-halt
# then open http://localhost:4000
```

`HA_URL`/`HA_TOKEN` are optional — without them, flows that don't need HA still run.

Start it as a **named node** too, so a dev shell can attach to the running app
(see Dev shell):

```sh
ERL_AFLAGS="-sname home_elixir -setcookie home_elixir" \
  HA_URL=wss://... HA_TOKEN=... mix run --no-halt
```

## Dev shell

The dev shell is real IEx **attached to the running app** — a distributed
connection into the app's VM, not a second app instance. This works when the
server is started as the named node `:home_elixir` (command above).

**In the browser** — open the **IEx** link in the web UI (or `/terminal`). It
opens a genuine `iex --remsh home_elixir` over xterm.js/WebSocket, so
`HomeElixir.FlowStore.list()`, the HA client, etc. all see the live instance.

**In a terminal:**

```sh
ERL_AFLAGS="-sname home_elixir_dev -setcookie home_elixir" iex --remsh home_elixir
```

The usual IEx helpers work. `HomeElixir.FlowStore.*` calls are node-aware, so
they reach the running app's server from the attached shell. If the server is
not a named node, the browser tab falls back to a self-contained `iex -S mix`.

## Flows

Each file in `flows/` is one flow module (`use HomeElixir.Flow`, `node/3`,
`wire/2`). Create/edit them in the web editor, or just drop a `.ex` file into
`flows/` and load it from the list page.

## Development

Developed with the help of Qwen 3.8.
