defmodule HomeElixir.HATest do
  use ExUnit.Case, async: false

  alias HomeElixir.{Config, FlowState, HA}

  setup_all do
    FlowState.start()
    Config.start()
    :ok
  end

  setup do
    System.put_env("HA_TOKEN", "env-token")
    System.put_env("SUPERVISOR_TOKEN", "sup-token")
    Application.put_env(:home_elixir, :ha_token, "config-token")

    on_exit(fn ->
      System.delete_env("HA_TOKEN")
      System.delete_env("SUPERVISOR_TOKEN")
      Application.delete_env(:home_elixir, :ha_token)
      Config.delete(:global, "ha_token")
    end)

    :ok
  end

  # ---- rest_base / rest_prefix ----

  test "rest_base keeps the supervisor proxy prefix" do
    with_url("ws://supervisor/core/api/websocket", fn ->
      assert HA.rest_base() == "http://supervisor/core"
      assert HA.rest_prefix() == "/core"
    end)
  end

  test "rest_base handles the alternate supervisor ws path" do
    with_url("ws://supervisor/core/websocket", fn ->
      assert HA.rest_base() == "http://supervisor/core"
      assert HA.rest_prefix() == "/core"
    end)
  end

  test "rest_base drops /api for direct core urls" do
    with_url("wss://ha.example.com/api/websocket", fn ->
      assert HA.rest_base() == "https://ha.example.com"
      assert HA.rest_prefix() == ""
    end)
  end

  test "rest_base keeps the port on direct urls" do
    with_url("ws://homeassistant:8123/api/websocket", fn ->
      assert HA.rest_base() == "http://homeassistant:8123"
      assert HA.rest_prefix() == ""
    end)
  end

  # ---- token/0 priority ----

  test "token: supervisor > env > config" do
    assert HA.token() == "sup-token"

    System.delete_env("SUPERVISOR_TOKEN")
    assert HA.token() == "env-token"

    System.delete_env("HA_TOKEN")
    assert HA.token() == "config-token"
  end

  test "token: stored login beats static config" do
    Config.put_global(:ha_token, "oauth-token")
    System.delete_env("SUPERVISOR_TOKEN")
    System.delete_env("HA_TOKEN")

    assert HA.token() == "oauth-token"
  end

  test "activate stores the token for later use" do
    System.delete_env("SUPERVISOR_TOKEN")
    System.delete_env("HA_TOKEN")
    Application.delete_env(:home_elixir, :ha_token)

    assert HA.activate("fresh-token") == :ok
    assert Map.get(Config.global_config(), "ha_token") == "fresh-token"
    assert HA.token() == "fresh-token"
  end

  # ---- pure state/history cores ----

  test "find_state returns the matching state or nil" do
    states = [%{"entity_id" => "light.a"}, %{"entity_id" => "light.b", "state" => "off"}]
    assert HomeElixir.HA.find_state(states, "light.b") == %{"entity_id" => "light.b", "state" => "off"}
    assert HomeElixir.HA.find_state(states, "light.zzz") == nil
  end

  test "device_entity_ids lists the device's entities" do
    regs = [
      %{"entity_id" => "e1", "device_id" => "D"},
      %{"entity_id" => "e2", "device_id" => "D"},
      %{"entity_id" => "e3", "device_id" => "Z"},
      %{"entity_id" => "e4"}
    ]

    assert HomeElixir.HA.device_entity_ids(regs, "D") == ["e1", "e2"]
    assert HomeElixir.HA.device_entity_ids(regs, "Z") == ["e3"]
    assert HomeElixir.HA.device_entity_ids(regs, "none") == []
  end

  test "filter_states keeps only the given ids, in order" do
    states = [%{"entity_id" => "e2"}, %{"entity_id" => "e1"}, %{"entity_id" => "zz"}]

    assert HomeElixir.HA.filter_states(states, ["e1", "e2"]) == [
             %{"entity_id" => "e1"},
             %{"entity_id" => "e2"}
           ]
  end

  test "build_range: nil is the last hour" do
    now = 1_700_000_000
    {s, e} = HomeElixir.HA.build_range(nil, now)
    assert unix(e) == now
    assert unix(s) == now - 3600
  end

  test "build_range: a number is a look-back in hours" do
    now = 1_700_000_000
    {s, e} = HomeElixir.HA.build_range(3, now)
    assert unix(e) == now
    assert unix(s) == now - 3 * 3600
  end

  test "build_range: an explicit pair is passed through" do
    {s, e} = HomeElixir.HA.build_range({1_700_000_000, 1_700_003_600}, 0)
    assert unix(s) == 1_700_000_000
    assert unix(e) == 1_700_003_600
  end

  test "flatten_history flattens a list of per-entity lists" do
    assert HomeElixir.HA.flatten_history([[%{"a" => 1}, %{"a" => 2}], [%{"b" => 3}]]) ==
             [%{"a" => 1}, %{"a" => 2}, %{"b" => 3}]

    # a bare map (not wrapped in a list) is tolerated
    assert HomeElixir.HA.flatten_history([%{"x" => 1}]) == [%{"x" => 1}]
  end

  # unix seconds for an ISO string, to compare build_range output without hardcoding.
  defp unix(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt)
  end

  defp with_url(url, fun) do
    System.put_env("HA_URL", url)

    try do
      fun.()
    after
      System.delete_env("HA_URL")
    end
  end
end
