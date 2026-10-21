# home_elixir v0.1.0 - API Reference

## Modules

- [HomeElixir](HomeElixir.md): A Node-RED-style flow engine for Home Assistant, in Elixir.
- [HomeElixir.Registry](HomeElixir.Registry.md): Loads and unloads flows and tracks which are running.

- Flows
  - [HomeElixir.Flow](HomeElixir.Flow.md): Declare a flow as an Elixir module.
  - [HomeElixir.FlowState](HomeElixir.FlowState.md): Persistent per-flow state, namespaced by the calling flow's module.
  - [HomeElixir.FlowStore](HomeElixir.FlowStore.md): Discovers flow `.ex` files and loads/unloads them at runtime.
  - [HomeElixir.FlowsHA](HomeElixir.FlowsHA.md): Exposes every flow as a switch in a single "Flows" device in Home Assistant,
via the Node-RED Companion integration. Each switch's state is the flow's
loaded state; toggling it in HA loads/unloads the flow.
  - [HomeElixir.Msg](HomeElixir.Msg.md): A message flowing through a flow, Node-RED-style. `payload` is the primary
value; `topic` and `data` carry metadata; extra fields live in `data`.

  - [HomeElixir.Node](HomeElixir.Node.md): Behaviour for flow nodes.

- Nodes
  - [HomeElixir.Nodes.Device](HomeElixir.Nodes.Device.md): Presents a device (entity) to Home Assistant via the Node-RED integration and
owns its state bidirectionally.
  - [HomeElixir.Nodes.Function](HomeElixir.Nodes.Function.md): Applies a function to each message. Config is `fun: &Mod.fun/1` (a remote
function). It receives the `HomeElixir.Msg` and returns a new `Msg` (or a raw
value, wrapped as `payload`), or `nil` to drop the message.

  - [HomeElixir.Nodes.Inject](HomeElixir.Nodes.Inject.md): Passthrough source node: re-emits each incoming message unchanged. Use it as
the entry point of a flow that starts from an external trigger (a web button
via the `ui:` config) rather than from an HA event.
  - [HomeElixir.Nodes.Logger](HomeElixir.Nodes.Logger.md): Logs each incoming message and produces no output. A debug/observation node
(the Node-RED `debug` equivalent), useful as a flow endpoint and for e2e.

  - [HomeElixir.Nodes.Schedule](HomeElixir.Nodes.Schedule.md): Source node: fires on wall-clock times given by a 5-field cron expression
(e.g. `"*/2 * * * *"` every 2 minutes, `"0 15 * * 1"` Monday at 3pm).
  - [HomeElixir.Nodes.Service](HomeElixir.Nodes.Service.md): Sink node: calls a Home Assistant service when a message arrives.
  - [HomeElixir.Nodes.Sink](HomeElixir.Nodes.Sink.md): Records every incoming message (most recent first). Useful as a flow endpoint
and for tests; read it back via `HomeElixir.Registry.node_state/2`.

  - [HomeElixir.Nodes.StateChanged](HomeElixir.Nodes.StateChanged.md): Source node: emits a message when a Home Assistant entity's state changes.

- Home Assistant
  - [HomeElixir.HA](HomeElixir.HA.md): Access to the shared, named `HomeElixir.HA.Client`.
  - [HomeElixir.HA.Client](HomeElixir.HA.Client.md): A client for the Home Assistant WebSocket API.
  - [HomeElixir.HA.LiveUpdate](HomeElixir.HA.LiveUpdate.md): Send and dismiss Android/iOS Home Assistant companion **Live Activities** to a
person's devices — the reusable core. Flows just call `update/3` / `dismiss/2`.
  - [HomeElixir.HA.OAuth](HomeElixir.HA.OAuth.md): Home Assistant local OAuth (authorization code + PKCE).
  - [HomeElixir.HA.OAuthStrategy](HomeElixir.HA.OAuthStrategy.md): The `OAuth2.Strategy.AuthCode` flow, minus the `Authorization: Basic` header.
  - [HomeElixir.HA.PendingLogins](HomeElixir.HA.PendingLogins.md): Shared store for in-flight OAuth logins, keyed by the `state` value.
  - [HomeElixir.HA.Transport.Mint](HomeElixir.HA.Transport.Mint.md): WebSocket transport backed by Mint + Mint.WebSocket.
  - [HomeElixir.NodeRedStatus](HomeElixir.NodeRedStatus.md): Tracks whether the Node-RED Companion integration is installed in Home
Assistant. Probed once at startup (and re-checkable on demand from the admin
page).
  - [HomeElixir.Nodered](HomeElixir.Nodered.md): Helpers for managing Node-RED-integration entities from Elixir.

- Web
  - [HomeElixir.Auth](HomeElixir.Auth.md): Local accounts (Mnesia), in-memory sessions (ETS), and PBKDF2 password
hashing via OTP `:crypto` — no external deps, so the hermetic Nix build is
untouched.
  - [HomeElixir.AuthGuard](HomeElixir.AuthGuard.md): Wraps `HomeElixir.Web` and enforces a session on every route except the public
ones (`/login`, `/api/login`, static assets, favicon). On success it assigns
`conn.assigns.user = {username, role}` and hands the conn to `HomeElixir.Web`;
on failure it redirects HTML requests to `/login` and answers `/api/*` with 401.

  - [HomeElixir.EntityBrowser](HomeElixir.EntityBrowser.md): Build an Area > Device > Entity tree of Home Assistant entities, for the
editor's entity browser. `build/3` is pure and assembles the tree from three
read-only HA lists; `tree/0` fetches them from the shared HA client.
  - [HomeElixir.Examples](HomeElixir.Examples.md): Bundled example flows, kept in a separate read-only `examples/` dir (outside the
user's `flows/` dir). They can be listed, viewed, and copied into the user's
flows (verbatim) so they can be edited. They are never loaded or run in place.

  - [HomeElixir.Log](HomeElixir.Log.md): In-memory ring buffer of recent log lines, fed by `HomeElixir.LogHandler`.
  - [HomeElixir.Terminal](HomeElixir.Terminal.md): Cowboy WebSocket handler that gives the browser a real IEx bridged over
xterm.js.
  - [HomeElixir.Web](HomeElixir.Web.md): Web UI + JSON API for managing flows: a list page, an inline-highlighted
editor for flow files, and a live-updating log page.

- Core
  - [HomeElixir.Config](HomeElixir.Config.md): Layered, editable configuration for flows.
  - [HomeElixir.Dep](HomeElixir.Dep.md): Install external Hex dependencies at runtime, Livebook-style, without editing
`mix.exs`.

