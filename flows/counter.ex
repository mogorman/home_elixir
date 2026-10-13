defmodule HomeElixir.Flows.Counter do
  @moduledoc """
  Example flow that tours every `HomeElixir.FlowState` operation with a live,
  in-sync display on the /controls page.

  The `count` node (HomeElixir.Nodes.Counter) keeps the total in **local node
  state**, synced from Mnesia on load and written back to Mnesia on every
  operation — so the "Count" badge is always current with no polling.

    | op         | payload | shown by                              |
    |------------|---------|---------------------------------------|
    | update     | "inc"   | "+1" button and the door event         |
    | update     | "dec"   | "-1" button                            |
    | write      | "set"   | "Reset" button (sets to the default)   |
    | delete     | "clear" | "Clear" button (removes the key)       |
    | read       | —       | the live "Count" badge                 |
    | initialize | —       | synced from Mnesia when the node loads |

  Point `sensor.front_door` at the event you want to count.
  """
  use HomeElixir.Flow

  # Normalize the door event into an "inc" for the counter node.
  def door_inc(_msg), do: "inc"

  # The stateful counter: local state + Mnesia, shown as a live badge.
  node("count", HomeElixir.Nodes.Counter, key: :count, default: 0,
       ui: %{type: "state", label: "Count"})

  # Web buttons (Inject re-emits the click payload into the counter).
  node("inc", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "+1", payload: "inc"})

  node("dec", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "-1", payload: "dec"})

  node("set", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Reset", payload: "set"})

  node("clear", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Clear", payload: "clear"})

  # Door event -> normalize to "inc" -> counter.
  node("door", HomeElixir.Nodes.StateChanged, entity_id: "sensor.front_door")
  node("door_bump", HomeElixir.Nodes.Function, fun: &__MODULE__.door_inc/1)

  wire("door", "door_bump")
  wire("door_bump", "count")
  wire("inc", "count")
  wire("dec", "count")
  wire("set", "count")
  wire("clear", "count")
end
