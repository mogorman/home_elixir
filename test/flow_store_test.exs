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

  @deep_mod HomeElixir.Flows.Rooms.Kitchen.DeepFlow

  @deep_src """
  defmodule HomeElixir.Flows.Rooms.Kitchen.DeepFlow do
    use HomeElixir.Flow

    node("in", HomeElixir.Nodes.Function, fun: &__MODULE__.id/1)
    node("out", HomeElixir.Nodes.Sink)
    wire("in", "out")

    def id(m), do: m
  end
  """

  setup do
    HomeElixir.FlowState.start()
    tmp = Path.join(System.tmp_dir!(), "flow_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "rooms/kitchen"))
    File.write!(Path.join(tmp, "store_test.ex"), @flow_src)
    File.write!(Path.join(tmp, "alt_flow.ex"), @alt_src)
    File.write!(Path.join(tmp, "rooms/test_flow.ex"), @nested_src)
    File.write!(Path.join(tmp, "rooms/kitchen/deep_flow.ex"), @deep_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Registry.unload(@mod)
      Registry.unload(@alt_mod)
      Registry.unload(@nested_mod)
      Registry.unload(@deep_mod)
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

  test "supports arbitrary folder depth" do
    flow = Enum.find(FlowStore.list(), &(&1.name == "rooms/kitchen/deep_flow"))
    assert flow.module == @deep_mod

    assert :ok = FlowStore.load("rooms/kitchen/deep_flow")
    assert Registry.loaded?(@deep_mod)
    assert :ok = FlowStore.unload("rooms/kitchen/deep_flow")
    refute Registry.loaded?(@deep_mod)
  end

  test "a flow file that fails to compile is still listed (broken), not fatal" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    File.write!(Path.join(tmp, "broken.ex"), "defmodule HomeElixir.Flows.BrokenX do use Nope")

    list = FlowStore.list()
    broken = Enum.find(list, &(&1.name == "broken"))
    assert broken.status == :broken
    assert broken.module == nil
    refute broken.loaded
    # and the store still lists the healthy flows
    assert Enum.any?(list, &(&1.name == "store_test"))
  end

  test "a broken flow can be fixed and reloaded (error cache follows the checksum)" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    path = Path.join(tmp, "store_test.ex")

    assert :ok = FlowStore.load("store_test")

    # Break it: the reload fails and the error is cached against this checksum.
    File.write!(path, "defmodule HomeElixir.Flows.StoreTest do\n  use HomeElixir.Flow\n  this is not elixir (\nend\n")
    assert {:error, :compile_error} = FlowStore.reload("store_test")

    # Fix it (new checksum): reload must succeed again — a stale error cached
    # against the old checksum must not pin the module to nil.
    File.write!(path, @flow_src)
    assert :ok = FlowStore.reload("store_test")
    assert Registry.loaded?(@mod)
  end

  test "load and unload push a flow_changed update to web clients" do
    HomeElixir.UI.Hub.subscribe(self())

    assert :ok = FlowStore.load("store_test")
    expect_flow_changed()

    assert :ok = FlowStore.unload("store_test")
    expect_flow_changed()
  end

  # Load/unload also log, and log lines are pushed too — skip those.
  defp expect_flow_changed do
    receive do
      {:ui_push, json} ->
        if Jason.decode!(json)["type"] == "flow_changed" do
          :ok
        else
          expect_flow_changed()
        end
    after
      500 -> flunk("timed out waiting for a flow_changed push")
    end
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
    # processing a message records last-triggered, surfaced on the list entry
    poll(fn -> HomeElixir.FlowState.last_triggered(@mod) end)
    assert Enum.find(FlowStore.list(), &(&1.name == "store_test")).last_triggered

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

  test "name_from_source preserves directory case, snake_cases only the file" do
    assert HomeElixir.Web.name_from_source("defmodule HomeElixir.Flows.Examples.NowClock do") ==
             "Examples/now_clock"

    assert HomeElixir.Web.name_from_source("defmodule HomeElixir.Flows.Counter do") == "counter"

    assert HomeElixir.Web.name_from_source("defmodule HomeElixir.Flows.A.B.DeepFlow do") ==
             "A/B/deep_flow"
  end

  test "list picks up a renamed module after the file changes (no restart)" do
    assert Enum.find(FlowStore.list(), &(&1.name == "store_test")).module ==
             HomeElixir.Flows.StoreTest

    p = Path.join(Application.get_env(:home_elixir, :flows_dir), "store_test.ex")
    File.write!(p, String.replace(File.read!(p), "HomeElixir.Flows.StoreTest", "HomeElixir.Flows.StoreTestRenamed"))

    # the checksum-changed file recompiles, so list shows the new module
    assert Enum.find(FlowStore.list(), &(&1.name == "store_test")).module ==
             HomeElixir.Flows.StoreTestRenamed
  end

  test "rename drops the old file and carries ownership to the new name" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    old = Path.join(tmp, "rename_src.ex")
    new = Path.join(tmp, "rename_dest.ex")

    File.write!(old, "defmodule HomeElixir.Flows.RenameSrc do\n  use HomeElixir.Flow\n  node(\"in\", HomeElixir.Nodes.Sink)\nend")
    File.write!(new, "defmodule HomeElixir.Flows.RenameDest do\n  use HomeElixir.Flow\n  node(\"in\", HomeElixir.Nodes.Sink)\nend")
    HomeElixir.FlowState.set_flow_owner("rename_src", "someone")

    assert :ok = FlowStore.rename("rename_src", "rename_dest")
    refute File.exists?(old)
    assert File.exists?(new)
    assert Enum.find(FlowStore.list(), &(&1.name == "rename_src")) == nil
    assert Enum.find(FlowStore.list(), &(&1.name == "rename_dest")) != nil
    assert HomeElixir.FlowState.flow_owner("rename_dest") == "someone"
    assert HomeElixir.FlowState.flow_owner("rename_src") == nil
  end

  test "archive force-unloads, flags the flow, and blocks load; unarchive restores" do
    assert :ok = FlowStore.load("alt_flow")
    assert Registry.loaded?(@alt_mod)

    assert :ok = FlowStore.archive("alt_flow")
    refute Registry.loaded?(@alt_mod)
    assert Enum.find(FlowStore.list(), &(&1.name == "alt_flow")).archived == true
    assert {:error, :archived} = FlowStore.load("alt_flow")

    assert :ok = FlowStore.unarchive("alt_flow")
    assert Enum.find(FlowStore.list(), &(&1.name == "alt_flow")).archived == false
    assert :ok = FlowStore.load("alt_flow")
    assert Registry.loaded?(@alt_mod)
    FlowStore.unload("alt_flow")
  end

  test "delete removes the flow file and clears its metadata" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    target = Path.join(tmp, "del_target.ex")

    File.write!(
      target,
      "defmodule HomeElixir.Flows.DelTarget do\n  use HomeElixir.Flow\n  node(\"in\", HomeElixir.Nodes.Sink)\nend"
    )

    assert File.exists?(target)
    HomeElixir.FlowState.set_flow_owner("del_target", "someone")

    assert :ok = FlowStore.delete("del_target")
    refute File.exists?(target)
    assert Enum.find(FlowStore.list(), &(&1.name == "del_target")) == nil
    assert HomeElixir.FlowState.flow_owner("del_target") == nil
    assert {:error, :not_found} = FlowStore.delete("del_target")
  end

  test "clone copies the flow file and module with a Clone suffix" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    clone_path = Path.join(tmp, "store_test_clone.ex")

    assert {:ok, "store_test_clone"} = FlowStore.clone("store_test")
    assert File.exists?(clone_path)

    src = File.read!(clone_path)
    assert src =~ "defmodule HomeElixir.Flows.StoreTestClone do"
    refute src =~ "defmodule HomeElixir.Flows.StoreTest do"

    clone = Enum.find(FlowStore.list(), &(&1.name == "store_test_clone"))
    assert clone.module == HomeElixir.Flows.StoreTestClone
    assert clone.loaded == false

    # the clone compiles, loads, and runs
    assert :ok = FlowStore.load("store_test_clone")
    assert Registry.loaded?(clone.module)
    FlowStore.unload("store_test_clone")

    # cloning the same flow again collides
    assert {:error, :exists} = FlowStore.clone("store_test")
    assert {:error, :not_found} = FlowStore.clone("nope")
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
