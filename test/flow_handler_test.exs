defmodule HomeElixir.FlowHandlerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Registry, HA}
  alias HomeElixir.HA.FakeTransport

  defmodule Flows.HandlerTest do
    use HomeElixir.Flow

    def handle(%{topic: "light.kitchen", payload: "on"}) do
      Application.put_env(:home_elixir, :handler_fired, System.monotonic_time())
    end

    # No catch-all clause — the Flow macro adds it.
  end

  # ---- helpers (mirrors nodes_test) ----

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
    poll(fn -> HA.Client.status(client) == :connected end)
    t
  end

  defp poll(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(1)

      if System.monotonic_time(:millisecond) < deadline, do: poll(fun), else: flunk("timed out")
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

  defp emit(t, sub_id, data) do
    event = %{"event_type" => "state_changed", "data" => data}
    FakeTransport.send_text(t, Jason.encode!(%{"id" => sub_id, "type" => "event", "event" => event}))
  end

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end

  # ---- tests ----

  test "handler flow runs handle/1 on a matching HA event" do
    t = start_ha!()
    on_exit(fn -> Registry.unload(Flows.HandlerTest); stop_ha() end)

    Application.delete_env(:home_elixir, :handler_fired)
    {:ok, _} = Registry.load(Flows.HandlerTest)
    sub = sent_until(t, &(&1 =~ "subscribe_events"))

    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    poll(fn -> not is_nil(Application.get_env(:home_elixir, :handler_fired)) end)
    assert Application.get_env(:home_elixir, :handler_fired)
  end

  test "non-matching events fall through to the macro's catch-all" do
    t = start_ha!()
    on_exit(fn -> Registry.unload(Flows.HandlerTest); stop_ha() end)

    Application.delete_env(:home_elixir, :handler_fired)
    {:ok, _} = Registry.load(Flows.HandlerTest)
    sub = sent_until(t, &(&1 =~ "subscribe_events"))

    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    poll(fn -> not is_nil(Application.get_env(:home_elixir, :handler_fired)) end)
    baseline = Application.get_env(:home_elixir, :handler_fired)

    # different entity → no re-fire
    emit(t, sub["id"], %{"entity_id" => "light.other", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    Process.sleep(200)
    assert Application.get_env(:home_elixir, :handler_fired) == baseline

    # same entity, different payload → no re-fire
    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "off"}})
    Process.sleep(200)
    assert Application.get_env(:home_elixir, :handler_fired) == baseline
  end
end
