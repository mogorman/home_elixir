defmodule HomeElixir.FlowStateTest do
  use ExUnit.Case, async: false

  alias HomeElixir.FlowState

  setup_all do
    FlowState.start()
    :ok
  end

  test "get / put / update within a flow scope" do
    FlowState.as(__MODULE__, fn ->
      assert FlowState.get(:n, :none) == :none
      FlowState.put(:n, 1)
      assert FlowState.get(:n) == 1
      assert FlowState.update(:n, &(&1 + 1)) == 2
      assert FlowState.get(:n) == 2
      FlowState.put(:n, 0)
    end)
  end

  test "delete removes a key" do
    FlowState.as(__MODULE__, fn ->
      FlowState.put(:d, 5)
      assert FlowState.get(:d) == 5
      FlowState.delete(:d)
      assert FlowState.get(:d, :gone) == :gone
      # deleting an absent key is a no-op
      assert FlowState.delete(:d) == :ok
    end)
  end

  test "flows are namespaced separately" do
    FlowState.as(:flow_a, fn -> FlowState.put(:k, :a) end)
    FlowState.as(:flow_b, fn -> FlowState.put(:k, :b) end)
    assert FlowState.as(:flow_a, fn -> FlowState.get(:k) end) == :a
    assert FlowState.as(:flow_b, fn -> FlowState.get(:k) end) == :b
  end

  test "calling outside a flow scope raises" do
    assert_raise RuntimeError, ~r/outside a flow/, fn -> FlowState.get(:x) end
  end
end
