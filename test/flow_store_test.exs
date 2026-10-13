defmodule HomeElixir.FlowStoreTest do
  use ExUnit.Case, async: false

  alias HomeElixir.{FlowStore, Registry}

  @mod HomeElixir.Flows.StoreTest

  @flow_src """
  defmodule HomeElixir.Flows.StoreTest do
    use HomeElixir.Flow

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.id/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")

    def id(m), do: m
  end
  """

  @alt_mod HomeElixir.Flows.AltFlow

  @alt_src """
  defmodule HomeElixir.Flows.AltFlow do
    use HomeElixir.Flow

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.id/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")

    def id(m), do: m
  end
  """

  @nested_mod HomeElixir.Flows.Rooms.TestFlow

  @nested_src """
  defmodule HomeElixir.Flows.Rooms.TestFlow do
    use HomeElixir.Flow

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.id/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")

    def id(m), do: m
  end
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "flow_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "rooms"))
    File.write!(Path.join(tmp, "store_test.ex"), @flow_src)
    File.write!(Path.join(tmp, "alt_flow.ex"), @alt_src)
    File.write!(Path.join(tmp, "rooms/test_flow.ex"), @nested_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Registry.unload(@mod)
      Registry.unload(@alt_mod)
      Registry.unload(@nested_mod)
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "lists, loads, unloads, and reloads a flow file" do
    store = Enum.find(FlowStore.list(), &(&1.name == "store_test"))
    assert store.module == HomeElixir.Flows.StoreTest
    assert store.loaded == false

    assert :ok = FlowStore.load("store_test")
    assert Registry.loaded?(@mod)
    assert Enum.find(FlowStore.list(), &(&1.name == "store_test")).loaded == true

    assert :ok = FlowStore.unload("store_test")
    refute Registry.loaded?(@mod)

    assert :ok = FlowStore.load("store_test")
    assert Registry.loaded?(@mod)
  end

  test "errors on an unknown flow" do
    assert {:error, :not_found} = FlowStore.load("nope")
  end

  test "discovers flows in subfolders with path-style names" do
    flow = Enum.find(FlowStore.list(), &(&1.name == "rooms/test_flow"))
    assert flow.module == @nested_mod

    assert :ok = FlowStore.load("rooms/test_flow")
    assert Registry.loaded?(@nested_mod)
    assert :ok = FlowStore.unload("rooms/test_flow")
    refute Registry.loaded?(@nested_mod)
  end

  test "check reports valid and broken source" do
    assert {:ok, "OK — compiles cleanly"} =
      FlowStore.check("defmodule HomeElixir.Flows.CheckValid do end")

    assert {:error, msg} = FlowStore.check("defmodule Broken do use Nope")
    assert msg =~ ~r/undefined|error|missing/i
  end

  test "reload restarts a loaded flow with fresh node state" do
    assert :ok = FlowStore.load("store_test")
    Registry.send_msg(@mod, "in", HomeElixir.Msg.new("x"))
    poll(fn -> length(Registry.node_state(@mod, "out") || []) >= 1 end)

    assert :ok = FlowStore.reload("store_test")
    assert Registry.loaded?(@mod)
    assert Registry.node_state(@mod, "out") == []
  end

  test "reload loads a not-loaded flow" do
    refute Registry.loaded?(@mod)
    assert :ok = FlowStore.reload("store_test")
    assert Registry.loaded?(@mod)
  end

  test "reload_all restarts loaded flows and leaves others unloaded" do
    assert :ok = FlowStore.load("store_test")
    Registry.send_msg(@mod, "in", HomeElixir.Msg.new("x"))
    poll(fn -> length(Registry.node_state(@mod, "out") || []) >= 1 end)
    refute Registry.loaded?(@alt_mod)

    assert :ok = FlowStore.reload_all()
    assert Registry.loaded?(@mod)
    assert Registry.node_state(@mod, "out") == []
    refute Registry.loaded?(@alt_mod)
  end

  defp poll(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(5)

      if System.monotonic_time(:millisecond) < deadline do
        poll(fun)
      else
        flunk("timed out")
      end
    end
  end
end
