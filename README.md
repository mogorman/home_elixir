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

## Dev shell

The dev shell is the **real IEx**, connected to the running app. Two ways:

**In a terminal:**

```sh
iex -S mix
```

**In the browser** — open the **IEx** link in the web UI (or `/terminal`). It
runs genuine IEx over xterm.js on a WebSocket. A fresh `iex -S mix` app instance
is spawned per session (so it runs alongside the server that hosts the UI).

Both boot the same supervision tree (flows, `HomeElixir.FlowStore`, the HA
client) and drop into IEx, so you can inspect and drive everything —
`HomeElixir.FlowStore.list()`, `HomeElixir.Registry`, the HA client, etc. All the
usual IEx helpers (`h/1`, `c/1`, `r/1`, `whereis/1`, `ls/1`, ...) work.

## Flows

Each file in `flows/` is one flow module (`use HomeElixir.Flow`, `node/3`,
`wire/2`). Create/edit them in the web editor, or just drop a `.ex` file into
`flows/` and load it from the list page.
