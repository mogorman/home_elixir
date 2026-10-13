defmodule HomeElixir.Flows.Examples.DemoDevice do
  @moduledoc """
  Example: a switch presented to Home Assistant and owned by the flow
  (Node-RED-companion style).

  - A `Device` node registers the `nodered` switch "Elixir Demo Switch" (under an
    "Elixir" device) and re-emits whenever it's toggled in the HA frontend.
  - The On/Off web buttons set the switch's state from the flow.

  Force-remove the entity anytime with:
      HomeElixir.Nodered.remove("home_elixir", "demo_switch")
  """
  use HomeElixir.Flow

  @server "home_elixir"
  @node "demo_switch"

  node("dev", HomeElixir.Nodes.Device,
    server_id: @server,
    node_id: @node,
    component: "switch",
    config: %{name: "Elixir Demo Switch", icon: "mdi:toggle-switch"},
    device_info: %{id: "elixir_demo", name: "Elixir", manufacturer: "home-elixir"},
    state: false,
    inherit: true,
    ui: %{type: "state", label: "Elixir Demo Switch"})

  node("log", HomeElixir.Nodes.Logger)
  wire("dev", "log")

  node("on", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Elixir Switch: On", payload: %{state: true}})
  wire("on", "dev")

  node("off", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Elixir Switch: Off", payload: %{state: false}})
  wire("off", "dev")

  node("reset", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Elixir Switch: Reset", payload: %{reset: true}})
  wire("reset", "dev")
end
