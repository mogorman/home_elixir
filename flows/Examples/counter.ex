defmodule HomeElixir.Flows.Examples.Counter do
  @moduledoc """
  Example flow that tours every `HomeElixir.FlowState` operation with a live,
  in-sync display on the /controls page, using the **handle pattern**: all the
  counting logic lives in `handle/1` clauses, fed by web buttons and a door
  event.

  `use HomeElixir.Flow` wires an HA `state_changed` source into `&handle/1`
  (the `__he_handle__` node); the buttons below are wired into it too, and its
  output feeds the display node so the badge stays live.

    | trigger                     | op      | shown by                              |
    |-----------------------------|---------|---------------------------------------|
    | "+1" button / door event    | update  | count +1                              |
    | "-1" button                 | update  | count -1                              |
    | "Reset" button              | write   | sets to 0                             |
    | "Clear" button              | delete  | badge shows "-"                       |
    | badge                       | read    | live value from Mnesia                |

  The only node is `Counter.Badge` (below), a display mirror so the
  state-badge machinery has something to push; it holds no counting logic.

  Point `sensor.front_door` at the event you want to count.
  """
  use HomeElixir.Flow

  alias HomeElixir.FlowState

  # All the counting logic: FlowState ops, persisted in Mnesia (survives
  # reloads and restarts). The door clause filters by topic since the handler
  # source sees every HA state change.
  def handle(%{payload: "inc"}), do: FlowState.update(:count, &(&1 + 1), 0)
  def handle(%{payload: "dec"}), do: FlowState.update(:count, &(&1 - 1), 0)
  def handle(%{payload: "set"}), do: FlowState.put(:count, 0)
  def handle(%{payload: "clear"}), do: FlowState.delete(:count)
  def handle(%{topic: "sensor.front_door"}), do: FlowState.update(:count, &(&1 + 1), 0)

  # Web buttons (Inject re-emits the click payload into the handler).
  node("inc", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "+1", payload: "inc"})

  node("dec", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "-1", payload: "dec"})

  node("set", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Reset", payload: "set"})

  node("clear", HomeElixir.Nodes.Inject,
       ui: %{type: "button", label: "Clear", payload: "clear"})

  # Display mirror: keeps the "Count" badge in sync (state badges are
  # node-based, so this is the one node left).
  node("count", __MODULE__.Badge, ui: %{type: "state", label: "Count"})

  wire("inc", "__he_handle__")
  wire("dec", "__he_handle__")
  wire("set", "__he_handle__")
  wire("clear", "__he_handle__")
  wire("__he_handle__", "count")
end

# Flow-local display node: mirrors FlowState's :count into node state on every
# message so the state badge updates live. No counting logic.
defmodule HomeElixir.Flows.Examples.Counter.Badge do
  @moduledoc false
  @behaviour HomeElixir.Node

  @impl true
  def init(_), do: %{state: HomeElixir.FlowState.get(:count)}

  @impl true
  def handle(_msg, _), do: {[nil], %{state: HomeElixir.FlowState.get(:count)}}
end
