defmodule HomeElixir.Nodes.CounterFlowTest do
  use ExUnit.Case, async: false

  alias HomeElixir.{FlowState, Msg, Registry}

  # A flow that mirrors HomeElixir.Flows.Examples.Counter: handle/1 does the
  # counting via FlowState; the buttons wire into the handler; a display mirror
  # node keeps the badge live.
  defmodule Flows.CounterUI do
    use HomeElixir.Flow

    alias HomeElixir.FlowState

    def handle(%{payload: "inc"}), do: FlowState.update(:count, &(&1 + 1), 0)
    def handle(%{payload: "dec"}), do: FlowState.update(:count, &(&1 - 1), 0)
    def handle(%{payload: "set"}), do: FlowState.put(:count, 0)
    def handle(%{payload: "clear"}), do: FlowState.delete(:count)

    defmodule Badge do
      @behaviour HomeElixir.Node

      @impl true
      def init(_), do: %{state: HomeElixir.FlowState.get(:count)}

      @impl true
      def handle(_msg, _), do: {[nil], %{state: HomeElixir.FlowState.get(:count)}}
    end

    node("count", __MODULE__.Badge, ui: %{type: "state", label: "Count"})

    node("inc", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "+1", payload: "inc"})
    node("dec", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "-1", payload: "dec"})
    node("set", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Reset", payload: "set"})
    node("clear", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Clear", payload: "clear"})

    wire("inc", "__he_handle__")
    wire("dec", "__he_handle__")
    wire("set", "__he_handle__")
    wire("clear", "__he_handle__")
    wire("__he_handle__", "count")
  end

  setup_all do
    FlowState.start()
    :ok
  end

  setup do
    Registry.unload(Flows.CounterUI)
    FlowState.as(Flows.CounterUI, fn -> FlowState.delete(:count) end)
    :ok
  end

  test "exposes a state element and buttons" do
    assert {:ok, _} = Registry.load(Flows.CounterUI)

    elements = Registry.ui_elements()
    assert Enum.any?(elements, fn e -> e.module == Flows.CounterUI and e.node_id == "inc" end)
    assert Enum.any?(elements, fn e ->
             e.module == Flows.CounterUI and e.node_id == "count" and e.ui.type == "state"
           end)
  end

  test "syncs local state from Mnesia on start" do
    FlowState.as(Flows.CounterUI, fn -> FlowState.put(:count, 42) end)
    assert {:ok, _} = Registry.load(Flows.CounterUI)
    # Local state is seeded from Mnesia immediately (no timer).
    assert count_state(Flows.CounterUI) == 42
  end

  test "local state and Mnesia stay in sync after updates" do
    assert {:ok, _} = Registry.load(Flows.CounterUI)

    click_until(Flows.CounterUI, "inc", "inc", 1)
    assert count_state(Flows.CounterUI) == 1
    assert persisted(Flows.CounterUI) == 1

    click_until(Flows.CounterUI, "dec", "dec", 0)
    assert count_state(Flows.CounterUI) == 0
    assert persisted(Flows.CounterUI) == 0

    # write (reset to default) and delete
    click_until(Flows.CounterUI, "inc", "inc", 3)
    click_until(Flows.CounterUI, "set", "set", 0)
    assert count_state(Flows.CounterUI) == 0
    assert persisted(Flows.CounterUI) == 0

    click_until(Flows.CounterUI, "clear", "clear", nil)
    assert count_state(Flows.CounterUI) == nil
    assert persisted(Flows.CounterUI) == nil
  end

  # ---- helpers ----

  # The node's local state (the display value).
  defp count_state(flow), do: flow |> Registry.node_state("count") |> Map.get(:state)

  # The persisted (Mnesia) value.
  defp persisted(flow), do: FlowState.as(flow, fn -> FlowState.get(:count, nil) end)

  # Click until the persisted value reaches `expected`. Pre-routing sends are
  # dropped (not queued), so this can't over-count.
  defp click_until(flow, node, payload, expected, attempts \\ 40) do
    Enum.reduce_while(1..attempts, :err, fn _, _ ->
      Registry.send_msg(flow, node, Msg.new(payload))
      Process.sleep(15)
      if persisted(flow) == expected, do: {:halt, :ok}, else: {:cont, :err}
    end)
  end
end
