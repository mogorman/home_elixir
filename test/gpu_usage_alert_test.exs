defmodule HomeElixir.GpuUsageAlertTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias HomeElixir.Flows.Examples.GpuUsageAlert, as: Gpu

  @min 60_000

  setup_all do
    Code.require_file(Path.expand("../examples/gpu_usage_alert.ex", __DIR__))
    :ok
  end

  test "crossing above arms the flag but does not alert yet" do
    {since, last_alert, alert?} = Gpu.decide(20.0, nil, nil, 0)
    assert since == 0
    assert last_alert == nil
    assert alert? == false
  end

  test "fires once sustained for 10 minutes" do
    {_, last_alert, alert?} = Gpu.decide(20.0, 0, nil, 10 * @min)
    assert alert? == true
    assert last_alert == 10 * @min
  end

  test "does not re-alert within the 5 minute gate" do
    {_, last_alert, alert?} = Gpu.decide(20.0, 0, 10 * @min, 12 * @min)
    assert alert? == false
    assert last_alert == 10 * @min
  end

  test "re-alerts after the 5 minute gate while still hot" do
    {_, last_alert, alert?} = Gpu.decide(20.0, 0, 10 * @min, 15 * @min)
    assert alert? == true
    assert last_alert == 15 * @min
  end

  test "a second sustained GPU is rate-limited by the global gate" do
    {_, last_alert, alert?} = Gpu.decide(20.0, 0, 10 * @min, 11 * @min)
    assert alert? == false
    assert last_alert == 10 * @min
  end

  test "cooling below threshold disarms; the global gate is preserved" do
    {since, last_alert, alert?} = Gpu.decide(5.0, 0, 15 * @min, 20 * @min)
    assert since == nil
    assert alert? == false
    assert last_alert == 15 * @min
  end

  test "unavailable / non-numeric is ignored (state unchanged)" do
    {since, last_alert, alert?} = Gpu.decide(nil, 0, nil, 5 * @min)
    assert since == 0
    assert last_alert == nil
    assert alert? == false
  end

  test "exactly at threshold (15) counts as hot" do
    {since, _, _} = Gpu.decide(15.0, nil, nil, 0)
    assert since == 0
  end
end
