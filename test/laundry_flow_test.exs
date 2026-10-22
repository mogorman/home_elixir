defmodule HomeElixir.LaundryFlowTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Registry, HA, FlowState}
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

  test "finish attributes the person seen at start, not at finish" do
    t = start_ha!()

    on_exit(fn ->
      FlowState.as(@flow, fn ->
        FlowState.delete(:washer_starter)
        FlowState.delete(:dryer_starter)
      end)

      Registry.unload(@flow)
      stop_ha()
    end)

    {:ok, _} = Registry.load(@flow)
    sub = wait_sub_id(t)

    # Start the wash while matthias is on the camera → stored as the starter.
    emit(t, sub, "sensor.washer_run_state", "Idle", "Running")
    settle(t, face_states("matthias"))

    # Finish later, when someone else is on the camera. The stored starter wins.
    emit(t, sub, "binary_sensor.washer_run_completed", "off", "on")
    frame = pump(t, face_states("jodie"), &(&1 =~ "\"service\":\"signal_mog\""))
    assert frame["service_data"]["message"] == "matthias finished the washing"
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

  # Respond to the start handler's face lookup so it stores the starter.
  defp settle(t, states, remaining \\ 60) do
    handled =
      Enum.any?(FakeTransport.sent(t), fn f ->
        case Jason.decode(f) do
          {:ok, %{"type" => "get_states", "id" => id}} ->
            FakeTransport.send_text(
              t,
              Jason.encode!(%{id: id, type: "result", success: true, result: states})
            )

            true

          _ ->
            false
        end
      end)

    if handled, do: :ok, else: (Process.sleep(5); if remaining > 0, do: settle(t, states, remaining - 1))
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
