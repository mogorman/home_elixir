defmodule HomeElixir.DeviceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Msg, Registry}
  alias HomeElixir.HA
  alias HA.FakeTransport

  defmodule Flows.DeviceTest do
    use HomeElixir.Flow

    node("dev", HomeElixir.Nodes.Device,
      server_id: "srv",
      node_id: "sw",
      component: "switch",
      config: %{name: "Test Switch"},
      state: false)

    node("out", HomeElixir.Nodes.Sink)
    wire("dev", "out")

    node("on", HomeElixir.Nodes.Inject, ui: %{type: "button", payload: %{state: true}})
    wire("on", "dev")
  end

  defmodule Flows.DeviceInheritTest do
    use HomeElixir.Flow

    node("dev", HomeElixir.Nodes.Device,
      server_id: "srv",
      node_id: "sw2",
      component: "switch",
      config: %{name: "Inh"},
      state: false,
      inherit: true)
  end

  # ---- helpers ----

  defp start_ha! do
    {:ok, client} =
      HA.Client.start_link(
        name: HA.client_name(),
        url: "ws://fake:8123/api/websocket",
        token: "tok",
        transport: FakeTransport,
        reconnect_delay: 10
      )

    t = HA.Client.transport_pid(client)
    FakeTransport.connected(t)
    FakeTransport.send_text(t, ~s({"type":"auth_ok"}))
    wait_status(client, :connected)
    %{client: client, t: t}
  end

  defp wait_status(client, status), do: poll(fn -> HA.Client.status(client) == status end)

  defp poll(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(1)

      if System.monotonic_time(:millisecond) < deadline do
        poll(fun)
      else
        flunk("timed out")
      end
    end
  end

  defp sent_until(transport, pred, remaining \\ 2_000) do
    case Enum.find(FakeTransport.sent(transport), pred) do
      nil when remaining > 0 ->
        Process.sleep(1)
        sent_until(transport, pred, remaining - 1)

      nil ->
        flunk("timed out waiting for an outbound frame")

      json ->
        Jason.decode!(json)
    end
  end

  # Push a channel frame until it lands in the sink (handles the post-load :route race).
  defp channel_until(t, frame, flow, sink_id, attempts \\ 20) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      FakeTransport.send_text(t, Jason.encode!(frame))

      case Registry.node_state(flow, sink_id) do
        [first | _] -> {:halt, first}
        _ -> Process.sleep(20); {:cont, nil}
      end
    end)
  end

  defp node_pid(flow, node_id) do
    [{pid, _}] = Elixir.Registry.lookup(HomeElixir.NodeLookup, {flow, node_id})
    pid
  end

  # ---- tests ----

  test "Device node registers via nodered/discovery" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)

    req = sent_until(t, &(&1 =~ "nodered/discovery"))
    assert req["component"] == "switch"
    assert req["server_id"] == "srv"
    assert req["node_id"] == "sw"
    assert req["config"]["name"] == "Test Switch"
    assert req["state"] == false
  end

  test "Device node emits into the flow when HA toggles it (bidirectional)" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    id = sent_until(t, &(&1 =~ "nodered/discovery"))["id"]

    msg =
      channel_until(
        t,
        %{"id" => id, "type" => "event", "event" => %{"type" => "state_changed", "state" => true}},
        Flows.DeviceTest,
        "out"
      )
    assert %Msg{payload: true, topic: "sw"} = msg
  end

  test "Device node sets HA state from an incoming message (nodered/entity)" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    _ = sent_until(t, &(&1 =~ "nodered/discovery"))

    Registry.send_msg(Flows.DeviceTest, "on", Msg.new(%{"state" => true}))

    req = sent_until(t, &(&1 =~ "nodered/entity"))
    assert req["server_id"] == "srv"
    assert req["node_id"] == "sw"
    assert req["state"] == true
  end

  test "Device node sends a false state (not coerced to nil)" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    _ = sent_until(t, &(&1 =~ "nodered/discovery"))

    Registry.send_msg(Flows.DeviceTest, "on", Msg.new(%{"state" => false}))

    req = sent_until(t, &(&1 =~ "nodered/entity"))
    assert req["state"] == false
  end

  test "Device node re-registers (re-sends discovery) after a reconnect" do
    %{client: client, t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    _ = sent_until(t, &(&1 =~ "nodered/discovery"))

    FakeTransport.close(t)
    t2 = wait_new_transport(client, t)
    FakeTransport.connected(t2)
    FakeTransport.send_text(t2, ~s({"type":"auth_ok"}))
    wait_status(client, :connected)

    assert Enum.any?(FakeTransport.sent(t2), &(&1 =~ "nodered/discovery"))
  end

  test "Device node resets to its default state on a reset payload" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    _ = sent_until(t, &(&1 =~ "nodered/discovery"))

    Registry.send_msg(Flows.DeviceTest, "dev", Msg.new(%{"state" => true}))
    req = sent_until(t, fn j -> j =~ "nodered/entity" and j =~ ~s("state":true) end)
    ack(t, req["id"])
    poll(fn -> Registry.node_state(Flows.DeviceTest, "dev").state == true end)
    assert Registry.node_state(Flows.DeviceTest, "dev").state == true

    Registry.send_msg(Flows.DeviceTest, "dev", Msg.new(%{reset: true}))
    req2 = sent_until(t, fn j -> j =~ "nodered/entity" and j =~ ~s("state":false) end)
    ack(t, req2["id"])
    poll(fn -> Registry.node_state(Flows.DeviceTest, "dev").state == false end)
    assert Registry.node_state(Flows.DeviceTest, "dev").state == false
  end

  defp ack(t, id) do
    FakeTransport.send_text(t, Jason.encode!(%{"id" => id, "type" => "result", "success" => true}))
  end

  test "Device node adopts inherited state without emitting into the flow" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceTest)
    _ = sent_until(t, &(&1 =~ "nodered/discovery"))

    send(node_pid(Flows.DeviceTest, "dev"), {:he_device_inherit, true})
    poll(fn -> Registry.node_state(Flows.DeviceTest, "dev").state == true end)
    assert Registry.node_state(Flows.DeviceTest, "dev").state == true
    assert Registry.node_state(Flows.DeviceTest, "out") == []
  end

  test "Device node inherits the entity's HA state via get_states on load" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.DeviceInheritTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.DeviceInheritTest)

    gs = sent_until(t, &(&1 =~ "get_states"))
    FakeTransport.send_text(t, Jason.encode!(%{
      "id" => gs["id"],
      "type" => "result",
      "success" => true,
      "result" => [%{"entity_id" => "switch.inh", "state" => "on", "attributes" => %{"__he" => "srv/sw2"}}]
    }))

    poll(fn -> (Registry.node_state(Flows.DeviceInheritTest, "dev") || %{})[:state] == "on" end)
    assert Registry.node_state(Flows.DeviceInheritTest, "dev").state == "on"
  end

  defp wait_new_transport(client, old) do
    poll(fn ->
      case HA.Client.transport_pid(client) do
        ^old -> false
        pid when is_pid(pid) -> true
        _ -> false
      end
    end)

    HA.Client.transport_pid(client)
  end

  # shared cleanup
  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end
end
