defmodule HomeElixir.Flows.Laundry do
  @moduledoc """
  Washer & dryer "it's done" notifier.

  When either LG ThinQ machine finishes a cycle — its `*_run_completed` binary
  sensor flips `off`/`unavailable` → `on` — the flow:

    1. reads the last recognized face from the basement Frigate camera
       (`sensor.basementcam_last_recognized_face`), using it when it isn't
       `None` (falls back to "you" otherwise);
    2. raises an Android/iOS **Live Activity** on the companion (`person.mog`),
       e.g. "matthias finished the washing"; and
    3. sends a **Signal** message with the same line.

  The badge on the /controls page shows the last result.

  ## Configuration

  Editable in the flow's config (panel → config); the sensible defaults are the
  constants below.

    * `person`         — the person whose companion gets the Live Activity (default `mog`)
    * `signal_service` — the Signal `notify` service to message (default `signal_mog`)
    * `face_sensor`    — the Frigate "last recognized face" sensor (default `sensor.basementcam_last_recognized_face`)

  The two trigger sensors are fixed here (the LG ThinQ `run_completed`
  binary sensors); change `@wash_sensor` / `@dry_sensor` if your machine exposes
  different ones.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  require Logger

  alias HomeElixir.FlowState
  alias HomeElixir.HA
  alias HomeElixir.HA.LiveUpdate

  # Trigger: the LG ThinQ "run completed" binary sensors.
  @wash_sensor "binary_sensor.washer_run_completed"
  @dry_sensor "binary_sensor.dryer_run_completed"

  # Defaults (overridable in the flow config).
  @person "mog"
  @signal_service "signal_mog"
  @face_sensor "sensor.basementcam_last_recognized_face"

  def setup do
    HomeElixir.Config.seed(%{
      person: @person,
      signal_service: @signal_service,
      face_sensor: @face_sensor
    })
  end

  # ---- handler: fires on a finish (the run-completed sensor's new state "on";
  # HA only emits state_changed on a real change, so this is the rising edge) ----

  def handle(%{payload: "on", topic: topic}) do
    case topic do
      @wash_sensor -> finish("washing", "mdi:washing-machine", "he_laundry_wash")
      @dry_sensor -> finish("drying", "mdi:hair-dryer", "he_laundry_dry")
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

  defp finish(activity, icon, tag) do
    person = HomeElixir.Config.get(:person, @person)
    message = "#{face()} finished the #{activity}"

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
