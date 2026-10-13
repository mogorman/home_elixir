defmodule HomeElixir.Flows.Examples.Counter do
  @moduledoc """
  Example flow that tours every `HomeElixir.FlowState` operation with a live,
  in-sync display on the /controls page, using the **handle pattern**: all the
  counting logic lives in `handle/1` clauses, fed by web buttons and a door
  event. One module plays both roles: the flow (its `handle/1`) and its own
  display node (its `handle/2`, a `HomeElixir.Node` callback — the arities
  don't clash).

  `use HomeElixir.Flow` wires an HA `state_changed` source into `&handle/1`
  (the `__he_handle__` node); the button nodes below are auto-wired into it
  (Inject nodes with no outgoing wire), and its output feeds the display node
  automatically (state-badge nodes with no input), so this flow has no wires
  at all. State-changing clauses return the FlowState op's result, which
  wakes the display node; unmatched events hit the catch-all, return nil and
  are dropped — so the display only runs when the state actually changes.

    | trigger                     | op      | shown by                              |
    |-----------------------------|---------|---------------------------------------|
    | "+1" button / door event    | update  | count +1                              |
    | "-1" button                 | update  | count -1                              |
    | "Reset" button              | write   | sets to 0                             |
    | "Clear" button              | delete  | badge shows "-"                       |
    | badge                       | read    | live value from Mnesia                |

  Point `sensor.front_door` at the event you want to count.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  # All the counting logic: FlowState ops, persisted in Mnesia (survives
  # reloads and restarts). The door clause filters by topic since the handler
  # source sees every HA state change.
  def handle(%{payload: "inc"}), do: FlowState.update(:count, &(&1 + 1), 0)
  def handle(%{payload: "dec"}), do: FlowState.update(:count, &(&1 - 1), 0)
  def handle(%{payload: "set"}), do: FlowState.put(:count, 0)
  def handle(%{payload: "clear"}), do: FlowState.delete(:count)
  def handle(%{topic: "sensor.front_door"}), do: FlowState.update(:count, &(&1 + 1), 0)

  # Node callbacks: this flow doubles as its own display mirror, keeping the
  # "Count" badge in sync (state badges are node-based, so a node is needed).
  @impl true
  def init(_), do: %{state: FlowState.get(:count)}

  @impl true
  def handle(_msg, _), do: {[nil], %{state: FlowState.get(:count)}}

  # Web buttons (Inject re-emits the click payload into the handler).
  node("inc", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "+1", payload: "inc"})

  node("dec", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "-1", payload: "dec"})

  node("set", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Reset", payload: "set"})

  node("clear", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Clear", payload: "clear"})

  # Display mirror (this module). No wires needed at all — unconnected Inject
  # nodes feed the handler, and state-badge nodes are fed by its output.
  node("count", __MODULE__, ui: %{type: "state", label: "Count"})
end
