defmodule HomeElixir.ConfigTest do
  use ExUnit.Case, async: false

  alias HomeElixir.Config
  alias HomeElixir.FlowState

  @flow String.to_atom("Elixir.HomeElixir.Flows.ZZConfigTest")
  @flow_name "zz_config_test"

  setup_all do
    FlowState.start()
    Config.start()
    :ok
  end

  # Wipe the keys this suite touches across every scope, so tests start clean.
  setup do
    Config.delete(@flow_name, "cfg")
    Config.delete(:global, "cfg")
    Config.delete(@flow_name, "cfg_s")
    Config.delete(:global, "cfg_gs")
    Config.delete(@flow_name, "cfg_sh")
    Config.delete(:global, "cfg_sh")
    Application.delete_env(:home_elixir, :cfg_app)
    Application.delete_env(:home_elixir, :cfg_g)
    Application.delete_env(:home_elixir, :cfg_sys_probe)
    :ok
  end

  test "ambient module maps to a flow name" do
    FlowState.as(@flow, fn -> Config.put_flow("cfg", "from-flow") end)
    assert Config.flow_config(@flow_name) == %{"cfg" => "from-flow"}
  end

  test "resolution order outside a flow" do
    # nothing set -> default (CFG_PROBE is not in the environment)
    assert Config.resolve("cfg_probe", "dflt") == {"dflt", :default}

    System.put_env("CFG_PROBE", "sysval")
    assert Config.resolve("cfg_probe") == {"sysval", :system}

    Application.put_env(:home_elixir, :cfg_probe, "appval")
    assert Config.resolve("cfg_probe") == {"appval", :app}

    Application.delete_env(:home_elixir, :cfg_probe)
  end

  test "global beats app/system" do
    Application.put_env(:home_elixir, :cfg_g, "app")
    Config.put(:global, "cfg_g", "gval")

    try do
      assert Config.resolve("cfg_g") == {"gval", :global}
    after
      Config.delete(:global, "cfg_g")
      Application.delete_env(:home_elixir, :cfg_g)
    end
  end

  test "flow value beats global; clearing it falls back" do
    Config.put(:global, "cfg_p", "g")

    try do
      FlowState.as(@flow, fn ->
        Config.put_flow("cfg_p", "f")
        assert Config.resolve("cfg_p") == {"f", :flow}

        Config.delete(@flow_name, "cfg_p")
        assert Config.resolve("cfg_p") == {"g", :global}
      end)
    after
      Config.delete(:global, "cfg_p")
    end
  end

  test "put/delete round-trip on the global scope" do
    Config.put(:global, "cfg", "a")
    assert Map.get(Config.global_config(), "cfg") == "a"

    Config.delete(:global, "cfg")
    assert Map.get(Config.global_config(), "cfg", "none") == "none"

    # deleting an absent key is a no-op
    assert Config.delete(:global, "cfg") == :ok
  end

  test "seed is only-if-absent and uses the ambient flow" do
    FlowState.as(@flow, fn ->
      Config.seed(%{cfg_s: "first"})
      assert Config.get("cfg_s") == "first"

      # re-seeding a different value is a no-op once the key exists
      Config.seed(%{cfg_s: "second"})
      assert Config.get("cfg_s") == "first"

      # after deleting, a re-seed takes the new value
      Config.delete(@flow_name, "cfg_s")
      Config.seed(%{cfg_s: "third"})
      assert Config.get("cfg_s") == "third"
    end)
  end

  test "seed does not shadow an existing value from a higher layer" do
    Config.put(:global, "cfg_sh", "global")

    try do
      FlowState.as(@flow, fn ->
        Config.seed(%{cfg_sh: "flow-default"})
        # the flow keeps the existing global value; no per-flow copy is stamped
        assert Config.resolve("cfg_sh") == {"global", :global}
        assert Config.flow_config(@flow_name) == %{}
      end)
    after
      Config.delete(:global, "cfg_sh")
    end
  end

  test "seed scope: :global seeds the global scope" do
    Config.seed(%{cfg_gs: "gv"}, scope: :global)
    assert Map.get(Config.global_config(), "cfg_gs") == "gv"
    assert Config.get("cfg_gs") == "gv"
  end

  test "secret? flags key-like names" do
    assert Config.secret?("llm_api_key")
    assert Config.secret?("ha_token")
    assert not Config.secret?("llm_url")
  end
end
