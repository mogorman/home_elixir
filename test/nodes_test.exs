defmodule HomeElixir.NodesTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Msg, Registry}
  alias HomeElixir.HA
  alias HA.FakeTransport

  # ---- test flows ----

  defmodule Flows.ServiceTest do
    use HomeElixir.Flow
    node("svc", HomeElixir.Nodes.Service, domain: "light", service: "turn_on")
  end

  defmodule Flows.StateChangedTest do
    use HomeElixir.Flow
    node("sc", HomeElixir.Nodes.StateChanged)
    node("out", HomeElixir.Nodes.Sink)
    wire("sc", "out")
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

  defp wait_status(client, status) do
    poll(fn -> HA.Client.status(client) == status end)
  end

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

  # Push the event until it lands in the sink (handles the post-load :route race).
  defp emit_until(t, sub_id, event, flow, sink_id, attempts \\ 15) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      FakeTransport.send_text(
        t,
        Jason.encode!(%{"id" => sub_id, "type" => "event", "event" => event})
      )

      case Registry.node_state(flow, sink_id) do
        [first | _] -> {:halt, first}
        _ -> Process.sleep(20); {:cont, nil}
      end
    end)
  end

  # ---- tests ----

  test "Service node fires call_service with config + message data" do
    _ = start_ha!()
    t = HA.Client.transport_pid(HA.client())
    on_exit(fn -> Registry.unload(Flows.ServiceTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.ServiceTest)
    Registry.send_msg(Flows.ServiceTest, "svc", Msg.new(%{"brightness" => 200}))

    req = sent_until(t, &(&1 =~ "call_service"))
    assert req["domain"] == "light"
    assert req["service"] == "turn_on"
    assert req["service_data"]["brightness"] == 200
  end

  test "StateChanged node emits a message on a matching state event" do
    _ = start_ha!()
    t = HA.Client.transport_pid(HA.client())
    on_exit(fn -> Registry.unload(Flows.StateChangedTest); stop_ha() end)

    {:ok, _} = Registry.load(Flows.StateChangedTest)

    # the node subscribed in init; grab the subscription id
    sub = sent_until(t, &(&1 =~ "subscribe_events"))
    assert sub["event_type"] == "state_changed"

    event = %{"entity_id" => "light.kitchen", "old_state" => "off", "new_state" => "on"}
    msg = emit_until(t, sub["id"], event, Flows.StateChangedTest, "out")

    assert %Msg{payload: "on", topic: "light.kitchen"} = msg
    assert msg.data.new_state == "on"
    assert msg.data.old_state == "off"
  end

  # shared cleanup
  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end
end
