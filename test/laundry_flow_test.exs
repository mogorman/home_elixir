defmodule HomeElixir.LaundryFlowTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Registry, HA}
  alias HomeElixir.HA.FakeTransport

  @flow HomeElixir.Flows.Examples.Laundry
  @face "sensor.basementcam_last_recognized_face"

  setup_all do
    Code.compile_file("examples/laundry.ex")
    :ok
  end

  test "washer off->on signals + live-activity with the last face" do
    t = start_ha!()

    on_exit(fn ->
      Registry.unload(@flow)
      stop_ha()
    end)

    {:ok, _} = Registry.load(@flow)
    sub = wait_sub_id(t)

    states = face_states("matthias")
    emit(t, sub, "binary_sensor.washer_run_completed", "off", "on")

    frame = pump(t, states, &(&1 =~ "\"service\":\"signal_mog\""))
    assert frame["domain"] == "notify"
    assert frame["service"] == "signal_mog"
    assert frame["service_data"]["message"] == "matthias finished the washing"

    # The Live Activity went out too (companion mobile_app, keyed by tag).
    pump(t, states, &(&1 =~ "he_laundry_wash"))
  end

  test "dryer off->on says drying (face case preserved)" do
    t = start_ha!()

    on_exit(fn ->
      Registry.unload(@flow)
      stop_ha()
    end)

    {:ok, _} = Registry.load(@flow)
    sub = wait_sub_id(t)

    states = face_states("Matthias")
    emit(t, sub, "binary_sensor.dryer_run_completed", "off", "on")

    frame = pump(t, states, &(&1 =~ "\"service\":\"signal_mog\""))
    assert frame["service_data"]["message"] == "Matthias finished the drying"
  end

  test "no recognized face (None) falls back to 'you'" do
    t = start_ha!()

    on_exit(fn ->
      Registry.unload(@flow)
      stop_ha()
    end)

    {:ok, _} = Registry.load(@flow)
    sub = wait_sub_id(t)

    states = face_states("None")
    emit(t, sub, "binary_sensor.washer_run_completed", "off", "on")

    frame = pump(t, states, &(&1 =~ "\"service\":\"signal_mog\""))
    assert frame["service_data"]["message"] == "you finished the washing"
  end

  test "off->off does not fire" do
    t = start_ha!()

    on_exit(fn ->
      Registry.unload(@flow)
      stop_ha()
    end)

    {:ok, _} = Registry.load(@flow)
    sub = wait_sub_id(t)

    emit(t, sub, "binary_sensor.washer_run_completed", "off", "off")
    Process.sleep(300)
    refute Enum.any?(FakeTransport.sent(t), &(&1 =~ "signal_mog"))
  end

  # ---- helpers ----

  defp face_states(face) do
    [
      %{"entity_id" => @face, "state" => face},
      %{
        "entity_id" => "person.mog",
        "state" => "home",
        "attributes" => %{"device_trackers" => ["device_tracker.mog"]}
      }
    ]
  end

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

  defp wait_sub_id(t), do: sent_until(t, &(&1 =~ "subscribe_events"))["id"]

  # Respond to every get_states (face + person lookups) and wait for the frame
  # matching `pred`, decoding it.
  defp pump(t, states, pred, remaining \\ 3_000) do
    for f <- FakeTransport.sent(t) do
      case Jason.decode(f) do
        {:ok, %{"type" => "get_states", "id" => id}} ->
          FakeTransport.send_text(
            t,
            Jason.encode!(%{id: id, type: "result", success: true, result: states})
          )

        _ ->
          :ok
      end
    end

    case Enum.find(FakeTransport.sent(t), pred) do
      nil when remaining > 0 ->
        Process.sleep(5)
        pump(t, states, pred, remaining - 5)

      nil ->
        flunk("timed out waiting for outbound frame")

      json ->
        Jason.decode!(json)
    end
  end

  defp emit(t, sub, entity, old, new) do
    data = %{entity_id: entity, old_state: %{"state" => old}, new_state: %{"state" => new}}
    event = %{"event_type" => "state_changed", "data" => data}
    FakeTransport.send_text(t, Jason.encode!(%{"id" => sub, "type" => "event", "event" => event}))
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

  defp poll(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(1)

      if System.monotonic_time(:millisecond) < deadline, do: poll(fun), else: flunk("timed out")
    end
  end

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end
end
