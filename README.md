# HomeElixir

A Node-RED-style flow engine for Home Assistant in Elixir. Flows are plain `.ex`
files in `flows/`; the app connects to Home Assistant over its WebSocket API and
runs the flows as an OTP supervision tree.

[![Open your Home Assistant instance and show the add add-ons and integrations page to install the add-on.](https://my.home-assistant.io/badges/supervisor_addon.svg)](https://my.home-assistant.io/redirect/supervisor_addon/?addon=88eff496_home-elixir&repository_url=https%3A%2F%2Fgithub.com%2Fmogorman%2Fhome_elixir)

> **Live notifications:** Live Activities work on iOS and Android, but the Android
> companion app currently has broken live-notification *icon* support — the icon
> does not render ([home-assistant/android#5758](https://github.com/home-assistant/android/issues/5758)).
> See the `liveupdate` example.

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

## Web UI

- `/` — flow list (load / unload / reload)
- `/edit` — create or edit a flow (highlighted editor with a live compile check)
- `/controls` — buttons / state widgets declared by loaded flows
- `/logs` — live app log
- `/terminal` — in-browser IEx attached to the running app

## Flows

Each file in `flows/` is one flow module (`use HomeElixir.Flow`, `node/3`,
`wire/2`). Create/edit them in the web editor, or drop a `.ex` file into
`flows/` and load it from the list page. The set of loaded flows is persisted
(in the Mnesia flow-state DB) and restored on start.

Subfolders group flows in the list (e.g. `flows/living_room/counter.ex` shows
under a collapsible `living_room` folder, matching a
`HomeElixir.Flows.LivingRoom.Counter` module).

### Writing a flow

Nodes are declared with `node(id, module, config)` and connected with
`wire(from, to)`; several sources can share a target with
`wire(["a", "b"], "c")`. In handler flows, `Inject` nodes with no outgoing
wire are connected to `handle/1`, and state-badge nodes (`ui: %{type: "state"}`)
with no input are fed by its output — both explicit wires override. A handler
returns a value to wake its output nodes (state-changing clauses return the
FlowState op's result); unmatched input returns nil and is dropped. A
`HomeElixir.Msg` flows from a source node along the wires; a node's output 0 is
forwarded to the next node(s).

```elixir
defmodule HomeElixir.Flows.Kitchen do
  use HomeElixir.Flow

  # An optional local transform, referenced by the Function node below.
  def shout(m), do: %{m | payload: m.payload |> to_string() |> String.upcase()}

  node("in",  HomeElixir.Nodes.Inject,   ui: %{type: "button", label: "Go"})
  node("cap", HomeElixir.Nodes.Function, fun: &__MODULE__.shout/1)
  node("out", HomeElixir.Nodes.Logger)
  wire("in", "cap")
  wire("cap", "out")
end
```

### Using an external library (Livebook-style)

A flow may define `setup/0`; it runs once when the flow is loaded, before any
node starts. Use `HomeElixir.Dep.install/1` inside it to pull a Hex dependency
onto the code path at runtime — no `mix.exs` edit:

```elixir
defmodule HomeElixir.Flows.NowClock do
  use HomeElixir.Flow

  def setup, do: HomeElixir.Dep.install([{:timex, "~> 3.7"}])

  def now(m), do: %{m | payload: Timex.now() |> Timex.format!("{h12}:{m} {am}")}

  node("trigger", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "What time is it?"})
  node("clock", HomeElixir.Nodes.Function, fun: &__MODULE__.now/1)
  node("log", HomeElixir.Nodes.Logger)
  wire("trigger", "clock")
  wire("clock", "log")
end
```

The build is cached in `~/.cache/home_elixir/deps`, so only the first load of a
dep set hits the network.

### Handler flows

For a flow that just reacts to Home Assistant state changes, define `handle/1`
instead of wiring nodes. The Flow macro auto-wires an HA `state_changed` source
to it and discards the return value — so a handler just matches the input it
cares about and does work. The catch-all clause is added for you, so write only
the clauses you need:

```elixir
defmodule HomeElixir.Flows.DoorWatch do
  use HomeElixir.Flow

  def handle(%{topic: "sensor.front_door", payload: "open"}) do
    # do work (fire a service, log, send a message, ...)
  end
end
```

The `topic` is the entity id and the `payload` is the new state; match on them
(or use guards / `=~`) to pick the changes you care about.

## Nodes

Built-in nodes live in `HomeElixir.Nodes`. A node is a module implementing
`HomeElixir.Node` (`handle/2`, optional `init/1` and `trigger/2`).

| Node | Role | Key config |
|------|------|-----------|
| `Inject` | Passthrough source; entry point for web-triggered flows | `ui` (button / state) |
| `Function` | Apply an Elixir function to each message | `fun: &Mod.fun/1` |
| `Sink` | Record messages (test / debug endpoint) | — |
| `Logger` | Log each message to the app log | — |
| `Service` | Call a Home Assistant service | `domain`, `service`, `data` |
| `StateChanged` | Emit on HA state changes | `entity_id` (optional) |
| `Device` | Present / own an HA entity via the Node-RED integration | `server_id`, `node_id`, `component`, `config`, `device_info`, `state` |

**Web controls:** add `ui: %{type: "button", label: "…"}` (or `type: "state"`)
to a node's config and it appears on `/controls`. Clicking a button sends a
message into that node.

## API

The app runs as an OTP application; these are the main entry points (all also
reachable from the web UI or the dev shell).

### `HomeElixir.FlowStore` — flow lifecycle

| Function | Description |
|----------|-------------|
| `list/0` | All flow files with their loaded state |
| `load(name)` / `unload(name)` | Start / stop a flow |
| `reload(name)` / `reload_all/0` | Recompile + restart from disk |
| `loaded?(name)` | Whether a flow is loaded |
| `click(name, node, payload)` | Send a message into a node (web controls) |
| `ui/0` / `flow_ui(name)` | UI elements, live-valued when loaded |
| `check(source)` | Compile-check a source string without loading |
| `forget(name)` | Drop the cached module atom (force recompile) |
| `restore/0` | Reload the persisted set (Mnesia flow-state DB) |

### `HomeElixir.Registry` — the supervised node tree

| Function | Description |
|----------|-------------|
| `load(module)` / `unload(module)` | Start / stop a flow module's nodes |
| `list/0` / `loaded?(module)` | Currently loaded flows |
| `send_msg(module, node, msg)` | Cast a message into a node |
| `node_state(module, node)` | Read a node's internal state (debug) |
| `ui_elements/0` | UI elements declared by loaded flows |

### Other

| Function | Description |
|----------|-------------|
| `HomeElixir.Msg.new(payload, opts)` | Build a message (`%{payload, topic, data, msgid}`) |
| `HomeElixir.Dep.install(deps)` | Install Hex deps at runtime (Livebook-style) |
| `HomeElixir.HA.client/0` / `connected?/0` | The shared HA WebSocket client |
| `HomeElixir.HA.Client.call(client, type, payload)` | Correlated HA request |
| `HomeElixir.HA.Client.fire(client, type, payload)` | Fire-and-forget HA request |
| `HomeElixir.HA.Client.subscribe_events(client, type, to)` | Subscribe to HA events |
| `HomeElixir.Nodered.remove(server_id, node_id)` | Force-delete a Node-RED device |

## Development

Developed with the help of Qwen 3.8.
