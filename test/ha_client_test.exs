defmodule HomeElixir.HA.ClientTest do
  use ExUnit.Case, async: true

  alias HomeElixir.HA
  alias HomeElixir.HA.FakeTransport

  setup do
    {:ok, client} =
      HA.Client.start_link(
        url: "ws://fake:8123/api/websocket",
        token: "tok",
        transport: FakeTransport,
        reconnect_delay: 10
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    %{client: client}
  end

  # ---- helpers ----

  defp connect!(client) do
    t = HA.Client.transport_pid(client)
    FakeTransport.connected(t)
    FakeTransport.send_text(t, ~s({"type":"auth_ok"}))
    wait_status(client, :connected)
    t
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
        poll(fun, deadline - System.monotonic_time(:millisecond))
      else
        flunk("timed out waiting")
      end
    end
  end

  # Return the decoded outbound message that satisfies `pred`.
  defp sent_until(transport, pred) do
    do_sent_until(transport, pred, 2_000)
  end

  defp do_sent_until(transport, pred, remaining) do
    case Enum.find(FakeTransport.sent(transport), pred) do
      nil when remaining > 0 ->
        Process.sleep(1)
        do_sent_until(transport, pred, remaining - 1)

      nil ->
        flunk("timed out waiting for an outbound frame matching #{inspect(pred)}")

      json ->
        Jason.decode!(json)
    end
  end

  # ---- tests ----

  test "refuses calls before it is connected", %{client: client} do
    assert {:error, {:not_connected, status}} = HA.Client.call(client, "get_states")
    assert status in [:connecting, :disconnected]
  end

  test "returns the correlated result", %{client: client} do
    t = connect!(client)
    task = Task.async(fn -> HA.Client.call(client, "get_states") end)

    req = sent_until(t, &(&1 =~ "get_states"))
    FakeTransport.send_text(t, Jason.encode!(%{
      "id" => req["id"], "type" => "result", "success" => true,
      "result" => [%{"entity_id" => "light.kitchen"}]
    }))

    assert Task.await(task) == [%{"entity_id" => "light.kitchen"}]
  end

  test "maps an HA error result to {:error, _}", %{client: client} do
    t = connect!(client)
    task = Task.async(fn -> HA.Client.call(client, "call_service", domain: "light", service: "explode") end)

    req = sent_until(t, &(&1 =~ "call_service"))
    FakeTransport.send_text(t, Jason.encode!(%{
      "id" => req["id"], "type" => "result", "success" => false,
      "error" => %{"code" => "invalid_service", "message" => "nope"}
    }))

    assert Task.await(task) == {:error, %{code: "invalid_service", message: "nope"}}
  end

  test "fans events out to subscribers", %{client: client} do
    t = connect!(client)
    me = self()

    ref = HA.Client.subscribe_events(client, "state_changed", me)
    assert is_integer(ref)

    sub = sent_until(t, &(&1 =~ "subscribe_events"))
    assert sub["event_type"] == "state_changed"

    event = %{"entity_id" => "light.kitchen", "new_state" => "on"}
    FakeTransport.send_text(t, Jason.encode!(%{"id" => ref, "type" => "event", "event" => event}))

    assert_receive {:ha_event, ^ref, ^event}, 1_000
  end

  test "reconnects, re-auths and re-subscribes after a drop", %{client: client} do
    t0 = connect!(client)
    me = self()
    HA.Client.subscribe_events(client, "state_changed", me)

    FakeTransport.close(t0)

    # Wait for the replacement transport; poll_pid_change is race-free here,
    # unlike a status check that can miss the short :disconnected window.
    t1 = poll_pid_change(client, t0)
    assert t1 != t0

    # the new transport must re-auth and re-subscribe; trigger the upgrade first
    FakeTransport.connected(t1)

    req = sent_until(t1, &(&1 =~ "auth"))
    assert req["access_token"] == "tok"

    FakeTransport.send_text(t1, ~s({"type":"auth_ok"}))
    wait_status(client, :connected)

    sub = sent_until(t1, &(&1 =~ "subscribe_events"))
    assert sub["event_type"] == "state_changed"
  end

  test "does not reconnect on auth_invalid", %{client: client} do
    t = HA.Client.transport_pid(client)
    FakeTransport.connected(t)
    FakeTransport.send_text(t, ~s({"type":"auth_invalid"}))

    wait_status(client, :disconnected)
    # give any (wrong) reconnect a chance to happen, then assert the transport is gone
    Process.sleep(50)
    assert HA.Client.transport_pid(client) == nil
  end

  defp poll_pid_change(client, old) do
    poll(fn ->
      t = HA.Client.transport_pid(client)
      is_pid(t) and t != old
    end)

    HA.Client.transport_pid(client)
  end
end
