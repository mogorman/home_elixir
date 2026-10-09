defmodule HomeElixir.HelloTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.HA
  alias HomeElixir.HA.FakeTransport

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
    t
  end

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end

  defp wait_status(client, status) do
    deadline = System.monotonic_time(:millisecond) + 2_000

    if HA.Client.status(client) == status do
      :ok
    else
      Process.sleep(1)

      if System.monotonic_time(:millisecond) < deadline do
        wait_status(client, status)
      else
        flunk("timed out")
      end
    end
  end

  defp sent_until(t, pred, remaining \\ 2_000) do
    case Enum.find(FakeTransport.sent(t), pred) do
      nil when remaining > 0 ->
        Process.sleep(1)
        sent_until(t, pred, remaining - 1)

      nil ->
        flunk("timed out waiting for an outbound frame")

      json ->
        Jason.decode!(json)
    end
  end

  test "hello/0 fires tts.speak with 'hello world' on the configured entity" do
    t = start_ha!()
    on_exit(fn -> stop_ha() end)

    assert :ok = HomeElixir.hello()

    req = sent_until(t, &(&1 =~ "call_service"))
    assert req["domain"] == "tts"
    assert req["service"] == "speak"
    assert req["service_data"]["message"] == "hello world"
    assert req["service_data"]["entity_id"] == HomeElixir.hello_entity_id()
  end

  test "hello/0 reports not_connected when no client is running" do
    stop_ha()
    assert {:error, :not_connected} = HomeElixir.hello()
  end

  test "hello_entity_id/0 honors the HA_HELLO_ENTITY env override" do
    System.put_env("HA_HELLO_ENTITY", "media_player.custom_clock")
    on_exit(fn -> System.delete_env("HA_HELLO_ENTITY") end)
    assert HomeElixir.hello_entity_id() == "media_player.custom_clock"
  end

  test "hello_entity_id/0 falls back to the configured engineering clock" do
    System.delete_env("HA_HELLO_ENTITY")
    assert HomeElixir.hello_entity_id() == "media_player.engineering_clock"
  end
end
