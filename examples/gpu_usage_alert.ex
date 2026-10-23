defmodule HomeElixir.Flows.Examples.GpuUsageAlert do
  @moduledoc """
  Example flow: alert on sustained GPU utilisation, with an Android/iOS Live
  Activity (companion) progress bar + elapsed timer and a Signal message.

  Uses the **handle pattern**: an HA `state_changed` source feeds every entity
  change into `handle/1`, which pattern-matches the three NVIDIA RTX 3090
  utilisation sensors (so it watches **all three cards at once**):

    * `sensor.deepthought_geforce_rtx_3090_0`
    * `sensor.deepthought_geforce_rtx_3090_1`
    * `sensor.deepthought_geforce_rtx_3090_2`

  For each card the flow tracks the moment its value first reached the
  threshold (`@threshold`, default 15) and raises the alert only once the
  **earliest** hot card has been at/above the threshold for at least
  `@sustain` minutes (default 10) — a short blip never alerts. While any card
  is hot the alert fires at most once per `@cooldown` minutes (default 5). A
  1-minute `Schedule` tick re-evaluates on a fixed cadence, so a card that is
  *pinned* at a constant high value (and therefore emits no further change
  events) still alerts once it has been hot long enough.

  Each alert:

    1. sends a **Signal** message via `@notify_service` (a `notify` service), and
    2. updates a **Live Activity** on `@person`'s companion device via
       `HomeElixir.HA.LiveUpdate`, keyed by a fixed tag. The activity shows a
       progress bar that fills **1% per alert** and a chronometer counting up
       from when the earliest card first went hot — i.e. how long *any* card has
       been running hot.

  When every card has dropped below the threshold the Live Activity is dismissed
  and the counter resets.

  **Android note:** the Android companion app currently has broken
  *live-notification icon* support (the icon does not render); a workaround
  exists — https://github.com/home-assistant/android/issues/5758#issuecomment-3297763341.

  ## Configuration

  Editable in the flow's config (panel → config); the sensible defaults are the
  constants below.

    * `threshold`      — utilisation % at/above which a card counts as hot (default `15`)
    * `sustain`        — minutes a card must stay hot before alerting (default `10`)
    * `cooldown`       — minutes between repeated alerts (default `5`)
    * `person`         — whose companion gets the Live Activity (default `mog`)
    * `signal_service` — the Signal `notify` service to message (default `signal_mog`)

  The badge on the /controls page shows which cards are hot and for how long.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  require Logger

  alias HomeElixir.FlowState
  alias HomeElixir.HA
  alias HomeElixir.HA.LiveUpdate
  alias HomeElixir.Config

  @sensors [
    "sensor.deepthought_geforce_rtx_3090_0",
    "sensor.deepthought_geforce_rtx_3090_1",
    "sensor.deepthought_geforce_rtx_3090_2"
  ]
  @threshold 15
  @sustain_min 10
  @cooldown_min 5
  @person "mog"
  @signal_service "signal_mog"
  @tag "gpu_hot"

  # ---- config (seeded defaults; editable in the UI) ----

  def setup do
    Config.seed(%{
      threshold: @threshold,
      sustain: @sustain_min,
      cooldown: @cooldown_min,
      person: @person,
      signal_service: @signal_service
    })
  end

  # ---- handler: the flow sees every HA state change and pattern-matches. ----

  # A watched card changed value: update its hot-since, then re-evaluate the
  # global alert state (the handler source is unfiltered, so the guard picks out
  # just the three GPUs).
  def handle(%{payload: payload, topic: topic}) when topic in @sensors do
    now = now_ms()
    since = set_since(parse_value(payload), read_since(key(topic)), now, threshold())
    FlowState.put(key(topic), since)
    evaluate(now)
  end

  # Periodic tick: re-evaluate on a fixed cadence, so a pinned (constant-value)
  # card — which emits no change events — still alerts once sustained, and the
  # badge's elapsed-time display stays fresh.
  def handle(%{payload: "tick"}), do: evaluate(now_ms())

  # (the catch-all `handle(_), do: nil` is added by the Flow macro)

  # ---- display mirror (state badge; this module doubles as its own node) ----

  @impl true
  def init(_), do: %{state: display()}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: display()}}

  # The 1-minute tick that drives the sustained-hot clock and the badge.
  node("tick", HomeElixir.Nodes.Schedule, cron: "* * * * *", payload: "tick")

  # The "GPU hot" badge.
  node("badge", __MODULE__, ui: %{type: "state", label: "GPU hot"})

  # ---- pure logic (unit-tested in test/gpu_usage_alert_test.exs) ----

  # Coerce an HA state to a number, or nil for "unavailable"/"unknown"/garbage.
  def parse_value(value) do
    case value do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # A card's hot-since after one reading. `value` is a number or nil (already
  # parsed); `since` is the previous hot-since (epoch ms) or nil. Crossing up
  # arms it to `now`; dropping below the threshold cools it (nil); an
  # unavailable reading leaves it unchanged.
  def set_since(value, since, now, threshold) do
    cond do
      is_nil(value) -> since
      value < threshold -> nil
      is_nil(since) -> now
      true -> since
    end
  end

  # The global gate over the set of currently-hot since-times. Returns
  # `{alert?, new_last_alert}`: alert once the earliest hot card has been hot for
  # at least `sustain`, then re-alert at most every `cooldown` while any stays
  # hot.
  def gate(hot_sinces, last_alert, now, sustain, cooldown) do
    earliest = Enum.min(hot_sinces)

    cond do
      now - earliest < sustain ->
        {false, last_alert}

      is_nil(last_alert) ->
        {true, now}

      now - last_alert >= cooldown ->
        {true, now}

      true ->
        {false, last_alert}
    end
  end

  # ---- orchestration ----

  defp evaluate(now) do
    sinces = @sensors |> Enum.map(&read_since(key(&1)))
    hot = Enum.reject(sinces, &is_nil/1)

    cond do
      hot == [] ->
        dismiss_if_needed()
        :ok

      true ->
        case gate(hot, FlowState.get(:gpu_last_alert, nil), now, sustain_ms(), cooldown_ms()) do
          {true, new_last} -> fire(hot, new_last)
          {false, _} -> :ok
        end
    end
  end

  defp fire(hot, new_last) do
    FlowState.put(:gpu_last_alert, new_last)
    count = FlowState.update(:gpu_alert_count, &(&1 + 1), 0)
    episode = read_int(:gpu_episode_since) || Enum.min(hot)
    FlowState.put(:gpu_episode_since, episode)
    send_live_update(count, episode)
    notify()
    count
  end

  defp dismiss_if_needed do
    if FlowState.get(:gpu_alert_count, 0) > 0 do
      LiveUpdate.dismiss(person(), @tag)
      FlowState.put(:gpu_alert_count, 0)
      FlowState.put(:gpu_episode_since, nil)
      FlowState.put(:gpu_last_alert, nil)
      Logger.info("GPU usage alert: all cards cooled — live activity dismissed")
    end
  end

  # Update the Live Activity: 1% progress per alert, chronometer counting up from
  # the episode start (the earliest card's hot-since).
  defp send_live_update(count, episode_ms) do
    LiveUpdate.update(person(), @tag, %{
      title: "GPU running hot",
      message: "Graphics cards running hot",
      progress: count,
      progress_max: 100,
      chronometer: true,
      when: DateTime.from_unix!(div(episode_ms, 1000)) |> DateTime.to_iso8601(),
      notification_icon: "mdi:memory",
      color: "#e53935"
    })
  end

  defp notify do
    case HA.client() do
      nil ->
        :ok

      client ->
        HA.Client.call(client, "call_service", %{
          domain: "notify",
          service: signal_service(),
          service_data: %{message: "Graphics cards running hot"}
        })

        Logger.info("GPU usage alert: notified — cards running hot, sustained")
    end
  end

  # ---- display ----

  defp display do
    hot =
      @sensors
      |> Enum.with_index()
      |> Enum.map(fn {sensor, idx} -> {idx, read_since(key(sensor))} end)
      |> Enum.reject(fn {_idx, since} -> is_nil(since) end)

    case hot do
      [] ->
        "cool"

      _ ->
        earliest = Enum.min_by(hot, fn {_idx, since} -> since end)
        elapsed = humanize(now_ms() - earliest)
        cards = hot |> Enum.map(fn {idx, _} -> "gpu#{idx}" end) |> Enum.join(",")
        "hot #{elapsed} (#{cards})"
    end
  end

  defp humanize(ms) do
    s = div(max(ms, 0), 1000)
    m = div(s, 60)
    h = div(m, 60)

    if h > 0 do
      "#{h}h #{rem(m, 60)}m"
    else
      "#{m}m #{rem(s, 60)}s"
    end
  end

  # ---- config accessors ----

  defp threshold, do: Config.get(:threshold, @threshold)
  defp sustain_ms, do: Config.get(:sustain, @sustain_min) * 60_000
  defp cooldown_ms, do: Config.get(:cooldown, @cooldown_min) * 60_000
  defp person, do: Config.get(:person, @person)
  defp signal_service, do: Config.get(:signal_service, @signal_service)

  # The per-sensor state key, from the sensor's position in the flow's list.
  defp key(entity) do
    idx = @sensors |> Enum.find_index(&(&1 == entity)) || 0
    String.to_atom("gpu#{idx}_since")
  end

  # Read a persisted hot-since. FlowState is disk-backed and outlives the code,
  # so a stale value from a prior version of this example (e.g. a tuple rather
  # than an epoch-ms integer) must not reach the arithmetic in display/0 or
  # gate/5 — a non-integer is treated as "not hot" (nil) and healed on the next
  # reading. This is what fixes the `:badarith` on a flow that predates the
  # integer-since format.
  defp read_since(key), do: read_int(key)

  # Read a persisted integer (epoch-ms), or nil if absent or a stale non-integer.
  def read_int(key) do
    case FlowState.get(key, nil) do
      v when is_integer(v) -> v
      _ -> nil
    end
  end

  defp now_ms, do: :os.system_time(:millisecond)
end
