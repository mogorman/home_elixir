defmodule HomeElixir.Flows.GpuUsageAlert do
  @moduledoc """
  Alerts (Signal to mog) when any deepthought RTX 3090 GPU runs hot.

  Event-driven (no cron): each GPU sensor's state change is handled here. When a
  GPU crosses >= 15% a flag is set; once it has stayed >= 15% for 10 minutes it
  sends a Signal, then repeats every 5 minutes while it remains hot. A single
  global 5-minute gate means at most one Signal per 5 minutes across all three
  GPUs. It disarms (and re-arms on the next heating) when the GPU cools below 15%.

  Replaces the Home Assistant `automation.gpu_usage_alert` — disable that
  automation once this flow is verified, to avoid duplicate Signals.
  """
  use HomeElixir.Flow

  require Logger

  alias HomeElixir.FlowState

  @sensors [
    "sensor.deepthought_geforce_rtx_3090_0",
    "sensor.deepthought_geforce_rtx_3090_1",
    "sensor.deepthought_geforce_rtx_3090_2"
  ]

  @threshold 15
  @sustain 10 * 60 * 1000
  @cooldown 5 * 60 * 1000
  @notify_service "signal_mog"
  @notify_message "Graphics cards are running hot"

  # The handler flow's auto StateChanged source feeds every sensor change here;
  # only the three GPU sensors act, everything else is dropped by the catch-all.
  def handle(%{topic: topic, payload: payload}) do
    if topic in @sensors, do: on_change(topic, payload)
  end

  # ---- per-event logic (applies the pure decision to FlowState) ----

  defp on_change(sensor, payload) do
    now = System.system_time(:millisecond)
    key = gpu_key(sensor, :since)
    old_since = FlowState.get(key)

    {since, last_alert, alert?} =
      decide(parse(payload), old_since, FlowState.get(:last_alert), now)

    FlowState.put(key, since)
    FlowState.put(:last_alert, last_alert)
    log_transition(sensor, old_since, since, alert?)

    if alert?, do: notify()

    :ok
  end

  # ---- pure decision (unit-tested): {new_since, new_last_alert, alert?} ----

  @doc false
  def decide(value, since, last_alert, now) do
    cond do
      is_nil(value) ->
        {since, last_alert, false}

      value < @threshold ->
        {nil, last_alert, false}

      true ->
        since = since || now
        alert? = now - since >= @sustain and (is_nil(last_alert) or now - last_alert >= @cooldown)
        {since, if(alert?, do: now, else: last_alert), alert?}
    end
  end

  defp log_transition(sensor, old_since, since, alert?) do
    cond do
      alert? ->
        Logger.info("gpu alert: #{sensor} running hot, sending Signal")

      is_nil(old_since) and not is_nil(since) ->
        Logger.info("gpu alert: #{sensor} crossed >= #{@threshold}%, armed (10 min to fire)")

      not is_nil(old_since) and is_nil(since) ->
        Logger.info("gpu alert: #{sensor} cooled below #{@threshold}%, disarmed")

      true ->
        :ok
    end
  end

  defp notify do
    case HomeElixir.HA.client() do
      nil ->
        Logger.warning("gpu alert: no HA client; notify skipped")

      client ->
        HomeElixir.HA.Client.call(client, "call_service", %{
          domain: "notify",
          service: @notify_service,
          service_data: %{message: @notify_message}
        })
    end
  end

  defp parse(payload) do
    case Float.parse(to_string(payload)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp gpu_key(sensor, field) do
    n = sensor |> String.split("_") |> List.last()
    :"gpu#{n}_#{field}"
  end
end
