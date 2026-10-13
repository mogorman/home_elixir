defmodule HomeElixir.Flows.Example.DemoSwitch do
  @moduledoc """
  Example: presents a switch to Home Assistant, toggled from the web UI.

  The /controls page shows two buttons (Demo Switch: On / Off). Clicking one
  calls `homeassistant.turn_on` / `homeassistant.turn_off` on `@switch_entity`,
  so the switch's real state in Home Assistant flips.

  Point `@switch_entity` at any switch you want to control.
  """
  use HomeElixir.Flow

  @switch_entity "switch.livingroomcam_snapshots"

  node("on", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Demo Switch: On"})
  node("on_svc", HomeElixir.Nodes.Service,
       domain: "homeassistant", service: "turn_on", data: %{"entity_id" => @switch_entity})

  node("off", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Demo Switch: Off"})
  node("off_svc", HomeElixir.Nodes.Service,
       domain: "homeassistant", service: "turn_off", data: %{"entity_id" => @switch_entity})

  wire("on", "on_svc")
  wire("off", "off_svc")
end
