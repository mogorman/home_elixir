defmodule HomeElixir.UITest do
  use ExUnit.Case, async: false

  alias HomeElixir.{FlowStore, Registry}

  defmodule ButtonFlow do
    use HomeElixir.Flow

    node("btn", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Go"})
    node("out", HomeElixir.Nodes.Sink)
    wire("btn", "out")
  end

  defmodule PlainFlow do
    use HomeElixir.Flow

    node("in", HomeElixir.Nodes.Inject)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")
  end

  @ui_src """
  defmodule HomeElixir.Flows.UiFlow do
    use HomeElixir.Flow

    node("btn", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Go"})
    node("out", HomeElixir.Nodes.Sink)
    wire("btn", "out")
  end
  """

  setup do
    Registry.unload(ButtonFlow)
    Registry.unload(PlainFlow)
    Registry.unload(HomeElixir.Flows.UiFlow)
    :ok
  end

  test "ui_elements lists ui nodes from loaded flows and skips the rest" do
    assert {:ok, _} = Registry.load(ButtonFlow)
    assert {:ok, _} = Registry.load(PlainFlow)

    elements = Registry.ui_elements()
    assert %{module: ButtonFlow, node_id: "btn", ui: %{type: "button", label: "Go"}} in elements
    refute Enum.any?(elements, &(&1.module == PlainFlow))
  end

  test "injecting a message into the ui node delivers it downstream" do
    assert {:ok, _} = Registry.load(ButtonFlow)
    Registry.send_msg(ButtonFlow, "btn", HomeElixir.Msg.new("clicked"))
    [msg] = wait_messages(ButtonFlow, "out", 1)
    assert msg.payload == "clicked"
  end

  test "FlowStore.ui is name-keyed and click injects into the node" do
    tmp = Path.join(System.tmp_dir!(), "ui_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "ui_flow.ex"), @ui_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)
    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    assert :ok = FlowStore.load("ui_flow")
    [%{name: "ui_flow", node: "btn", type: "button", label: "Go"}] = FlowStore.ui()

    assert :ok = FlowStore.click("ui_flow", "btn")
    [msg] = wait_messages(HomeElixir.Flows.UiFlow, "out", 1)
    assert msg.topic == "btn"

    assert :ok = FlowStore.unload("ui_flow")
    assert {:error, :not_loaded} = FlowStore.click("ui_flow", "btn")
  end

  test "flow_ui returns a flow's declared ui elements without loading it" do
    tmp = Path.join(System.tmp_dir!(), "ui_flowui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "ui_flow.ex"), @ui_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)
    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    assert [%{name: "ui_flow", node: "btn", type: "button", label: "Go", value: nil}] =
      FlowStore.flow_ui("ui_flow")
  end

  defp wait_messages(flow, node_id, count, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    msgs = Registry.node_state(flow, node_id)

    cond do
      is_list(msgs) and length(msgs) >= count ->
        msgs

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for #{count} msg(s) on #{inspect(node_id)}")

      true ->
        Process.sleep(10)
        wait_messages(flow, node_id, count, timeout)
    end
  end
end
