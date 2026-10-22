defmodule HomeElixir.Flows.Examples.Laundry do
  @moduledoc """
  Washer & dryer "it's done" notifier, attributed to who **started** the cycle.

  When either LG ThinQ machine **starts** a cycle — its `*_run_state` sensor
  flips to the running value (default `Running`) — the flow reads the last
  recognized face from the basement Frigate camera
  (`sensor.basementcam_last_recognized_face`) and **stores it as the starter**
  (that's the person who put the laundry in). It keeps that person until the
  next start overwrites it.

  When the machine **finishes** — its `*_run_completed` binary sensor flips
  `off`/`unavailable` → `on` — the flow notifies the stored starter (falling
  back to the face it sees at that moment if it never saw a start):

    1. raises an Android/iOS **Live Activity** on the companion (`person.mog`),
       e.g. "matthias finished the washing"; and
    2. sends a **Signal** message with the same line.

  The badge on the /controls page shows the last result.

  ## Configuration

  Editable in the flow's config (panel → config); the sensible defaults are the
  constants below.

    * `person`         — the person whose companion gets the Live Activity (default `mog`)
    * `signal_service` — the Signal `notify` service to message (default `signal_mog`)
    * `face_sensor`    — the Frigate "last recognized face" sensor (default `sensor.basementcam_last_recognized_face`)
    * `running_state`  — the run-state value that means a cycle just started (default `Running`)

  The trigger sensors are fixed here (the LG ThinQ `run_state` / `run_completed`
  sensors); change `@wash_sensor` / `@dry_sensor` / `@wash_run_state` /
  `@dry_run_state` if your machine exposes different ones.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  require Logger

  alias HomeElixir.FlowState
  alias HomeElixir.HA
  alias HomeElixir.HA.LiveUpdate

  # Triggers: the LG ThinQ "run completed" binary sensors (finish) and the
  # "run state" sensors (start — when they flip to the running value).
  @wash_sensor "binary_sensor.washer_run_completed"
  @dry_sensor "binary_sensor.dryer_run_completed"
  @wash_run_state "sensor.washer_run_state"
  @dry_run_state "sensor.dryer_run_state"

  # Defaults (overridable in the flow config).
  @person "mog"
  @signal_service "signal_mog"
  @face_sensor "sensor.basementcam_last_recognized_face"
  @running_state "Running"

  def setup do
    HomeElixir.Config.seed(%{
      person: @person,
      signal_service: @signal_service,
      face_sensor: @face_sensor,
      running_state: @running_state
    })
  end

  # ---- handler: the flow sees every state_changed event and pattern-matches.

  # Start: the run-state sensor flips to the running value. Whoever is on the
  # basement camera right now started it — store them and use them for the
  # matching finish (until the next start overwrites them).
  def handle(%{payload: payload, topic: topic}) when topic in [@wash_run_state, @dry_run_state] do
    if payload == HomeElixir.Config.get(:running_state, @running_state) do
      key = if topic == @wash_run_state, do: :washer_starter, else: :dryer_starter
      starter = face()
      FlowState.put(key, starter)
      Logger.info("laundry: #{topic} started — attributing to #{starter}")
    end

    nil
  end

  # Finish: the run-completed sensor's rising edge ("on"). Notify the person we
  # stored at start; fall back to the current face if we never saw a start.
  def handle(%{payload: "on", topic: topic}) do
    case topic do
      @wash_sensor -> finish("washing", "mdi:washing-machine", "he_laundry_wash", :washer_starter)
      @dry_sensor -> finish("drying", "mdi:hair-dryer", "he_laundry_dry", :dryer_starter)
      _ -> nil
    end
  end

  # (the catch-all `handle(_), do: nil` is added by the Flow macro)

  # ---- display mirror (state badge) ----

  @impl true
  def init(_), do: %{state: FlowState.get(:last, "—")}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:last, "—")}}

  node("badge", __MODULE__, ui: %{type: "state", label: "Laundry"})

  # ---- internals ----

  defp finish(activity, icon, tag, starter_key) do
    person = HomeElixir.Config.get(:person, @person)
    starter = FlowState.get(starter_key, nil)
    who = if is_binary(starter) and starter != "", do: starter, else: face()
    message = "#{who} finished the #{activity}"

    FlowState.put(:last, message)

    case LiveUpdate.update(person, tag, %{
           title: "Laundry done",
           message: message,
           notification_icon: icon,
           notification_icon_color: "#1e88e5",
           color: "#1e88e5",
           alert_once: true
         }) do
      {:ok, n} when n > 0 ->
        Logger.info("laundry: live activity sent (#{message})")

      {:error, reason} ->
        Logger.debug("laundry: live activity skipped: #{inspect(reason)}")
    end

    case HA.client() do
      nil ->
        Logger.debug("laundry: no HA client; Signal skipped")

      client ->
        HA.Client.call(client, "call_service", %{
          domain: "notify",
          service: HomeElixir.Config.get(:signal_service, @signal_service),
          service_data: %{message: message}
        })

        Logger.info("laundry: signal sent (#{message})")
    end

    message
  end

  # The last recognized basement face, or "you" when none (None/empty/absent).
  defp face do
    sensor = HomeElixir.Config.get(:face_sensor, @face_sensor)

    case HA.state(sensor) do
      {:ok, st} ->
        case Map.get(st, "state") do
          s when is_binary(s) ->
            if String.downcase(s) in ["none", ""], do: "you", else: s

          _ ->
            "you"
        end

      _ ->
        "you"
    end
  end
end
