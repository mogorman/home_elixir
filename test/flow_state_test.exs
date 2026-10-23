defmodule HomeElixir.FlowStateTest do
  use ExUnit.Case, async: false

  alias HomeElixir.FlowState
  alias HomeElixir.FlowStore

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

  test "loaded_names/save_loaded_names round-trip, dedupes, keeps empty set" do
    prev = FlowState.loaded_names()

    try do
      FlowState.save_loaded_names(["a", "b"])
      assert FlowState.loaded_names() == ["a", "b"]

      FlowState.save_loaded_names([])
      assert FlowState.loaded_names() == []

      FlowState.save_loaded_names(["x", "x", "y"])
      assert FlowState.loaded_names() == ["x", "y"]
    after
      if is_list(prev), do: FlowState.save_loaded_names(prev)
    end
  end

  test "archive / unarchive / is_archived? round-trip" do
    assert FlowState.is_archived?("zz-arch-test") == false

    try do
      FlowState.archive("zz-arch-test")
      assert FlowState.is_archived?("zz-arch-test") == true
      assert "zz-arch-test" in FlowState.archived_names()
      # idempotent
      FlowState.archive("zz-arch-test")
      assert Enum.filter(FlowState.archived_names(), &(&1 == "zz-arch-test")) == ["zz-arch-test"]

      FlowState.unarchive("zz-arch-test")
      assert FlowState.is_archived?("zz-arch-test") == false
    after
      FlowState.unarchive("zz-arch-test")
    end
  end

  test "forget_flow clears a flow's metadata entries" do
    name = "zz-forget-test"

    try do
      FlowState.set_flow_owner(name, "someone")
      FlowState.save_loaded_names((FlowState.loaded_names() || []) ++ [name])
      FlowState.record_load(name, "abc123", "defmodule X do end")
      FlowState.archive(name)

      assert FlowState.flow_owner(name) == "someone"
      assert name in FlowState.loaded_names()
      assert name in FlowState.ever_loaded_names()
      assert FlowState.loaded_source(name) == "defmodule X do end"
      assert FlowState.is_archived?(name)

      FlowState.forget_flow(name)

      assert FlowState.flow_owner(name) == nil
      assert name not in FlowState.loaded_names()
      assert name not in FlowState.ever_loaded_names()
      assert FlowState.loaded_source(name) == nil
      assert FlowState.is_archived?(name) == false
    after
      FlowState.forget_flow(name)
    end
  end

  test "forget_flow_runtime clears a flow's persisted values (the stale-state bug)" do
    mod = :zz_runtime_forget_flow

    try do
      FlowState.as(mod, fn -> FlowState.put(:gpu0_since, {1, 1_792_783_128_528}) end)
      FlowState.as(mod, fn -> assert FlowState.get(:gpu0_since) == {1, 1_792_783_128_528} end)

      FlowState.forget_flow_runtime(mod)

      FlowState.as(mod, fn -> assert FlowState.get(:gpu0_since, :gone) == :gone end)
    after
      FlowState.forget_flow_runtime(mod)
    end
  end

  test "last_triggered records, lists, and forgets by module" do
    key = :"Elixir.HomeElixir.Flows.ZZTriggerTest"

    try do
      assert FlowState.last_triggered(key) == nil
      FlowState.record_triggered(key)
      assert is_integer(FlowState.last_triggered(key))
      assert Map.has_key?(FlowState.all_last_triggered(), key)

      # recording again updates the timestamp
      before = FlowState.last_triggered(key)
      FlowState.record_triggered(key)
      assert FlowState.last_triggered(key) >= before

      FlowState.forget_triggered(key)
      assert FlowState.last_triggered(key) == nil
      # forgetting an absent key is a no-op
      assert FlowState.forget_triggered(key) == :ok
    after
      FlowState.forget_triggered(key)
    end
  end

  test "sweep_orphans drops only the undeclared module, preserves the rest + metadata" do
    keep = :"Elixir.HomeElixir.Flows.ZZSweepKeep"
    orphan = :"Elixir.HomeElixir.Flows.ZZSweepOrphan"

    try do
      FlowState.as(keep, fn -> FlowState.put(:v, :kept) end)
      FlowState.as(orphan, fn -> FlowState.put(:v, :dropped) end)
      FlowState.set_flow_owner("zz-sweep-name", "someone")

      # Sweep every currently-present module EXCEPT the orphan, so only the
      # orphan is dropped and unrelated flow state is left alone.
      declared =
        FlowState.dump_runtime()
        |> Map.keys()
        |> Enum.map(&String.to_atom/1)
        |> MapSet.new()
        |> MapSet.delete(orphan)

      FlowState.sweep_orphans(declared)

      FlowState.as(keep, fn -> assert FlowState.get(:v) == :kept end)
      FlowState.as(orphan, fn -> assert FlowState.get(:v, :gone) == :gone end)
      # the app-metadata record is never touched by the sweep
      assert FlowState.flow_owner("zz-sweep-name") == "someone"
    after
      FlowState.forget_flow("zz-sweep-name")
      FlowState.forget_flow_runtime(keep)
      FlowState.forget_flow_runtime(orphan)
    end
  end

  test "declared_modules finds defmodule across flow files (incl. a broken body)" do
    tmp = Path.join(System.tmp_dir!(), "he_declared_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    orig = Application.get_env(:home_elixir, :flows_dir)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      if orig, do: Application.put_env(:home_elixir, :flows_dir, orig)
    end)

    File.write!(Path.join(tmp, "good.ex"), "defmodule HomeElixir.Flows.Good do end")
    File.write!(Path.join(tmp, "broken.ex"), "defmodule HomeElixir.Flows.Broken do\n  not valid @@@\nend")

    mods = FlowStore.declared_modules()
    assert :"Elixir.HomeElixir.Flows.Good" in mods
    assert :"Elixir.HomeElixir.Flows.Broken" in mods
    refute :"Elixir.HomeElixir.Flows.Absent" in mods
  end
end
