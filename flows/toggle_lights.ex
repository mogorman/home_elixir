defmodule HomeElixir.Flows.ToggleLights do
  @moduledoc """
  Example flow with a web control: a button on the /controls page toggles the
  living room lights.
  """
  use HomeElixir.Flow

  node("trigger", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Toggle Bedroom Lights"})

  node("action", HomeElixir.Nodes.Service,
       domain: "light",
       service: "toggle",
       data: %{"entity_id" => "light.living_room_main_lights"})

  wire("trigger", "action")
end
