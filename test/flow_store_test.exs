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

  setup do
    tmp = Path.join(System.tmp_dir!(), "flow_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "store_test.ex"), @flow_src)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "lists, loads, unloads, and reloads a flow file" do
    [flow] = FlowStore.list()
    assert flow.name == "store_test"
    assert flow.module == HomeElixir.Flows.StoreTest
    assert flow.loaded == false

    assert :ok = FlowStore.load("store_test")
    assert Registry.loaded?(@mod)
    assert [flow] = FlowStore.list()
    assert flow.loaded == true

    assert :ok = FlowStore.unload("store_test")
    refute Registry.loaded?(@mod)

    assert :ok = FlowStore.load("store_test")
    assert Registry.loaded?(@mod)
  end

  test "errors on an unknown flow" do
    assert {:error, :not_found} = FlowStore.load("nope")
  end

  test "check reports valid and broken source" do
    assert {:ok, "OK — compiles cleanly"} =
      FlowStore.check("defmodule HomeElixir.Flows.CheckValid do end")

    assert {:error, msg} = FlowStore.check("defmodule Broken do use Nope")
    assert msg =~ ~r/undefined|error|missing/i
  end
end
