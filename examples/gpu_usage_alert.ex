defmodule HomeElixir.Flows.Examples.GpuUsageAlert do
  @moduledoc """
  Example flow: alert on sustained GPU utilisation, with an Android/iOS Live
  Activity (companion) progress bar + elapsed timer.

  Watches three NVIDIA RTX 3090 utilisation sensors:

    * `sensor.deepthought_geforce_rtx_3090_0`
    * `sensor.deepthought_geforce_rtx_3090_1`
    * `sensor.deepthought_geforce_rtx_3090_2`

  For each card the flow tracks when its value first reached `@threshold` and
  raises the alert only if it has been at/above the threshold for at least
  `@sustain` (default 10 minutes) — a short blip never alerts. While the GPU is
  hot the alert fires at most once per `@cooldown` (default 5 minutes).

  Each alert:

    1. fires `@notify_service` (a `notify` service, e.g. `signal_mog`), and
    2. updates a **Live Activity** (Android/iOS Home Assistant companion app) via
       the core `HomeElixir.HA.LiveUpdate`, keyed by a fixed tag. The activity
       shows a progress bar that fills **1% per alert** and a count-up timer of
       how long the GPUs have been hot.

  When every card has dropped below the threshold the Live Activity is dismissed
  and the counter resets.

  **Android note:** the Android companion app currently has broken
  *live-notification icon* support (the icon does not render) —
  https://github.com/home-assistant/android/issues/5758.

  Per-sensor state is tracked in disk-backed flow state (survives restarts) as a
  `:gpuN_since` key (the epoch-ms `DateTime` the card first went hot, `nil` when
  cooled); the flow-level alert counter, episode start, and cooldown gate live
  under the `:gpu_alert_count`, `:gpu_hot_since`, and `:last_alert` keys.

  ## Configuration

  * **GPU sensor** (entity): which card's utilisation this alert watches.
  * **Utilisation %** (threshold, default `15`): alert when a card stays at or
    above this utilisation.
  * **Sustained for** (minutes, default `10`): the card must stay at/above the
    threshold this long before alerting.
  * **Cooldown** (minutes, default `5`): minimum time between repeated alerts.
  """
  use HomeElixir.Flow

  require Logger

  alias HomeElixir.{FlowState, HA}
  alias HomeElixir.HA.LiveUpdate

  @sensors [
    "sensor.deepthought_geforce_rtx_3090_0",
    "sensor.deepthought_geforce_rtx_3090_1",
    "sensor.deepthought_geforce_rtx_3090_2"
  ]
  @threshold 15
  @sustain 10 * 60 * 1000
  @cooldown 5 * 60 * 1000
  @notify_service "signal_mog"
  @person "mog"
  @tag "gpu_hot"

  def input_schema do
    [
      %{key: "entity", type: "select", items: @sensors,
        label: "GPU sensor", required: true, help: "Which card's utilisation this alert watches."}
    ]
  end

  def config_schema do
    [
      %{key: "threshold", type: "number", default: @threshold, label: "Utilisation %",
        help: "Alert when a card stays at or above this utilisation."},
      %{key: "sustain", type: "number", default: 10, unit: "min", min: 0, label: "Sustained for",
        help: "Minutes the card must stay at/above the threshold before alerting."},
      %{key: "cooldown", type: "number", default: 5, unit: "min", min: 0, label: "Cooldown",
        help: "Minutes between repeated alerts."}
    ]
  end

  def init(config) do
    %{
      entity: Map.get(config, :entity),
      threshold: cfg(config, :threshold, @threshold),
      sustain: cfg_min(config, :sustain, 10) * 60 * 1000,
      cooldown: cfg_min(config, :cooldown, 5) * 60 * 1000
    }
  end

  def subscribe(flow) do
    case flow.entity do
      entity when is_binary(entity) -> [entity]
      _ -> []
    end
  end

  def on_init do
    :ok = FlowState.put(:last_alert, nil)
    :ok = FlowState.put(:gpu_alert_count, 0)
    :ok = FlowState.put(:gpu_hot_since, nil)
  end

  def run(flow, event) do
    client = HA.client()
    now = :os.system_time(:millisecond)

    with {:ok, value} <- parse_value(event),
         _ <- HA.Client.call(client, "update_entity", %{
                entity_id: flow.entity_id,
                attributes: %{"value" => value}
              }) do
      since = FlowState.get(key(flow.entity))

      {new_since, last_alert, should_alert?} =
        decide(value, since, FlowState.get(:last_alert), now, flow.sustain, flow.cooldown)

      FlowState.put(key(flow.entity), new_since)

      if new_since == nil do
        if all_cooled?() do
          if FlowState.get(:gpu_alert_count, 0) > 0 do
            LiveUpdate.dismiss(@person, @tag)
            FlowState.put(:gpu_alert_count, 0)
            FlowState.put(:gpu_hot_since, nil)
          end
        end
      else
        if should_alert? do
          FlowState.put(:last_alert, last_alert)
          count = FlowState.get(:gpu_alert_count, 0) + 1
          FlowState.put(:gpu_alert_count, count)
          hot_since =
            case FlowState.get(:gpu_hot_since) do
              nil -> new_since
              prev -> min(prev, new_since)
            end

          FlowState.put(:gpu_hot_since, hot_since)
          send_live_update(count, hot_since)
          notify(client, flow.name)
        end
      end
    end
  rescue
    e ->
      Logger.error("GPU usage alert flow error: #{Exception.message(e)}\n" <>
                     Exception.format_stacktrace(__STACKTRACE__))
  end

  # Decide (new_since, last_alert, alert?) for a reading. Pure — unit-tested in
  # `test/gpu_usage_alert_test.exs`; the flow's `run/2` only handles the IO
  # (state, signal, Live Activity). Timestamps are epoch milliseconds.
  def decide(value, since, last_alert, now, sustain \\ @sustain, cooldown \\ @cooldown) do
    cond do
      value == nil ->
        {since, last_alert, false}

      value < @threshold ->
        {nil, last_alert, false}

      since == nil ->
        {now, last_alert, false}

      last_alert == nil ->
        alert? = now - since >= sustain
        new_last = if alert?, do: now, else: last_alert
        {since, new_last, alert?}

      true ->
        alert? = now - last_alert >= cooldown
        new_last = if alert?, do: now, else: last_alert
        {since, new_last, alert?}
    end
  end

  # Update the Live Activity: 1% progress per alert, count-up timer from the
  # episode start.
  defp send_live_update(count, hot_since_ms) do
    payload = %{
      title: "GPU running hot",
      message: "Graphics cards running hot",
      progress: count,
      progress_max: 100,
      chronometer: true,
      when: DateTime.from_unix!(div(hot_since_ms, 1000)) |> DateTime.to_iso8601(),
      notification_icon: "mdi:memory",
      color: "#e53935"
    }

    case LiveUpdate.update(@person, @tag, payload) do
      {:ok, n} when n > 0 -> :ok
      {:error, reason} -> Logger.debug("Live Activity skipped for #{@person}: #{inspect(reason)}")
    end
  end

  # Every card cooled? (all per-sensor `since` keys nil.)
  defp all_cooled?() do
    @sensors |> Enum.all?(fn sensor -> is_nil(FlowState.get(key(sensor))) end)
  end

  # The per-sensor state key, from the sensor's position in the flow's list.
  defp key(entity) do
    idx = @sensors |> Enum.find_index(&(&1 == entity)) || 0
    String.to_atom("gpu#{idx}_since")
  end

  defp notify(client, name) do
    HA.Client.call(client, "call_service", %{
      domain: "notify",
      service: @notify_service,
      service_data: %{message: "Graphics cards running hot"}
    })

    if client != nil do
      Logger.info("Alert fired: #{name} GPU utilisation at/above threshold, sustained")
    end
  end

  defp cfg(config, key, default), do: Map.get(config, key, default)

  defp cfg_min(config, key, default) do
    config
    |> Map.get(key, default)
    |> then(fn v -> if is_integer(v) and v >= 0, do: v, else: default end)
  end

  defp parse_value(event) do
    case event.state do
      v when is_number(v) -> {:ok, v}
      s when is_binary(s) ->
        case Float.parse(s) do
          {f, ""} -> {:ok, f}
          _ -> {:error, "not a number: #{inspect(s)}"}
        end

      _ -> {:error, "not a number: #{inspect(event.state)}"}
    end
  end
end
