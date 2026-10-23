defmodule HomeElixir.GpuUsageAlertTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias HomeElixir.Flows.Examples.GpuUsageAlert, as: Gpu
  alias HomeElixir.FlowState

  @min 60_000
  @sustain 10 * @min
  @cooldown 5 * @min

  setup_all do
    Code.require_file(Path.expand("../examples/gpu_usage_alert.ex", __DIR__))
    :ok
  end

  # ---- parse_value ----

  test "parse_value parses numeric strings and numbers" do
    assert Gpu.parse_value("100") == 100.0
    assert Gpu.parse_value("12.5") == 12.5
    assert Gpu.parse_value(42) == 42
    assert Gpu.parse_value(15.0) == 15.0
  end

  test "parse_value returns nil for non-numeric / unavailable" do
    assert Gpu.parse_value("unavailable") == nil
    assert Gpu.parse_value("unknown") == nil
    assert Gpu.parse_value("") == nil
    assert Gpu.parse_value(nil) == nil
  end

  # ---- set_since ----

  test "crossing above threshold arms the since" do
    assert Gpu.set_since(20.0, nil, 0, 15) == 0
  end

  test "exactly at threshold counts as hot" do
    assert Gpu.set_since(15.0, nil, 0, 15) == 0
  end

  test "dropping below threshold cools to nil" do
    assert Gpu.set_since(5.0, 0, 100, 15) == nil
  end

  test "staying hot keeps the original since" do
    assert Gpu.set_since(30.0, 0, 100, 15) == 0
  end

  test "unavailable reading leaves since unchanged" do
    assert Gpu.set_since(nil, 0, 100, 15) == 0
  end

  # ---- gate ----

  test "no alert before the earliest card is sustained" do
    assert Gpu.gate([0], nil, 9 * @min, @sustain, @cooldown) == {false, nil}
  end

  test "alerts once the earliest card is sustained" do
    assert Gpu.gate([0], nil, 10 * @min, @sustain, @cooldown) == {true, 10 * @min}
  end

  test "does not re-alert within the cooldown gate" do
    assert Gpu.gate([0], 10 * @min, 12 * @min, @sustain, @cooldown) == {false, 10 * @min}
  end

  test "re-alerts after the cooldown gate while still hot" do
    assert Gpu.gate([0], 10 * @min, 15 * @min, @sustain, @cooldown) == {true, 15 * @min}
  end

  test "the earliest card drives the sustained check across multiple cards" do
    # card0 went hot at t=0, card1 at t=8min. At t=9min card0 is not yet
    # sustained (9 < 10) -> no alert, even though card1 is also hot.
    assert Gpu.gate([0, 8 * @min], nil, 9 * @min, @sustain, @cooldown) == {false, nil}
    # at t=10min card0 is sustained -> alert (the chronometer keys to t=0).
    assert Gpu.gate([0, 8 * @min], nil, 10 * @min, @sustain, @cooldown) == {true, 10 * @min}
  end

  # ---- read_int: stale persisted-state tolerance (the :badarith guard) ----

  test "read_int returns a stored epoch-ms integer" do
    FlowState.as(Gpu, fn ->
      FlowState.put(:gpu0_since, 1_792_783_128_528)
      assert Gpu.read_int(:gpu0_since) == 1_792_783_128_528
      FlowState.delete(:gpu0_since)
    end)
  end

  test "read_int returns nil for a stale non-integer (e.g. an old tuple value)" do
    FlowState.as(Gpu, fn ->
      FlowState.put(:gpu0_since, {1, 1_792_783_128_528})
      assert Gpu.read_int(:gpu0_since) == nil
      FlowState.delete(:gpu0_since)
    end)
  end
end
