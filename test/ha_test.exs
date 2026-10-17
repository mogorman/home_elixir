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

  defp with_url(url, fun) do
    System.put_env("HA_URL", url)

    try do
      fun.()
    after
      System.delete_env("HA_URL")
    end
  end
end
