defmodule HomeElixir do
  @moduledoc """
  A Node-RED-style flow engine for Home Assistant, in Elixir.

  Flows are plain `.ex` files in `flows/`; the app connects to Home Assistant
  over its WebSocket API and runs the flows as an OTP supervision tree.

  ## The big picture

  | Module | Role |
  |--------|------|
  | `HomeElixir.Flow` | The `use HomeElixir.Flow` macro — declare nodes + wires in a flow module |
  | `HomeElixir.FlowStore` | Flow lifecycle: `list`, `load`, `unload`, `reload`, `click`, `check` |
  | `HomeElixir.Registry` | The supervised node tree that backs the loaded flows |
  | `HomeElixir.Node` | The node behaviour (`handle/2`, optional `init/1`, `trigger/2`) |
  | `HomeElixir.Nodes` | Built-in nodes: `Inject`, `Function`, `Service`, `StateChanged`, `Device`, ... |
  | `HomeElixir.HA` | The shared Home Assistant WebSocket client |
  | `HomeElixir.Msg` | The message that flows along the wires |
  | `HomeElixir.Dep` | Install a Hex dependency at runtime (Livebook-style) |

  ## Quickstart

  Write a flow module, then load it from the web UI or `flows/`:

  ```elixir
  defmodule HomeElixir.Flows.Kitchen do
    use HomeElixir.Flow

    def shout(m), do: %{m | payload: m.payload |> to_string() |> String.upcase()}

    node("in",  HomeElixir.Nodes.Inject,   ui: %{type: "button", label: "Go"})
    node("cap", HomeElixir.Nodes.Function, fun: &__MODULE__.shout/1)
    node("out", HomeElixir.Nodes.Logger)
    wire("in", "cap")
    wire("cap", "out")
  end
  ```

  The **Guide** (listed under *Extras*) covers writing flows, handler flows,
  web controls, and the dev shell. The in-app **Documentation** page renders the
  same guide; this site is the full module reference.
  """
end
