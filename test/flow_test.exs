defmodule HomeElixir.FlowTest do
  use ExUnit.Case, async: false

  defmodule TransformFlow do
    use HomeElixir.Flow

    def exclaim(m), do: %{m | payload: m.payload <> "!"}

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.exclaim/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")
  end

  defmodule FanoutFlow do
    use HomeElixir.Flow

    def identity(m), do: m

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.identity/1)
    node("a", HomeElixir.Nodes.Sink)
    node("b", HomeElixir.Nodes.Sink)
    wire("in", "a")
    wire("in", "b")
  end

  defmodule DropFlow do
    use HomeElixir.Flow

    def drop(_m), do: nil

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.drop/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")
  end

  setup do
    HomeElixir.Registry.unload(TransformFlow)
    HomeElixir.Registry.unload(FanoutFlow)
    HomeElixir.Registry.unload(DropFlow)
    :ok
  end

  test "forwards and transforms a message" do
    assert {:ok, _} = HomeElixir.Registry.load(TransformFlow)
    assert HomeElixir.Registry.loaded?(TransformFlow)

    HomeElixir.Registry.send_msg(TransformFlow, "in", HomeElixir.Msg.new("hi"))
    [msg] = wait_messages(TransformFlow, "out", 1)
    assert %HomeElixir.Msg{payload: "hi!"} = msg
  end

  test "fans one node out to many" do
    assert {:ok, _} = HomeElixir.Registry.load(FanoutFlow)
    HomeElixir.Registry.send_msg(FanoutFlow, "in", HomeElixir.Msg.new("x"))

    [a] = wait_messages(FanoutFlow, "a", 1)
    [b] = wait_messages(FanoutFlow, "b", 1)
    assert a.payload == "x"
    assert b.payload == "x"
  end

  test "drops the message when the function returns nil" do
    assert {:ok, _} = HomeElixir.Registry.load(DropFlow)
    HomeElixir.Registry.send_msg(DropFlow, "in", HomeElixir.Msg.new("x"))
    Process.sleep(50)
    assert [] = HomeElixir.Registry.node_state(DropFlow, "out")
  end

  test "unload stops the flow and allows reload" do
    assert {:ok, _} = HomeElixir.Registry.load(TransformFlow)
    assert :ok = HomeElixir.Registry.unload(TransformFlow)
    refute HomeElixir.Registry.loaded?(TransformFlow)

    assert {:ok, _} = HomeElixir.Registry.load(TransformFlow)
    assert {:error, :already_loaded} = HomeElixir.Registry.load(TransformFlow)
  end

  defp wait_messages(flow, node_id, count, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(flow, node_id, count, deadline)
  end

  defp wait_loop(flow, node_id, count, deadline) do
    msgs = HomeElixir.Registry.node_state(flow, node_id)

    cond do
      is_list(msgs) and length(msgs) >= count ->
        msgs

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for #{count} msg(s) on #{inspect(node_id)}; got #{inspect(msgs)}")

      true ->
        Process.sleep(10)
        wait_loop(flow, node_id, count, deadline)
    end
  end
end
