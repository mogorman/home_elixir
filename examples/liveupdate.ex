defmodule HomeElixir.Flows.Examples.LiveUpdate do
  @moduledoc """
  Example flow to exercise `HomeElixir.HA.LiveUpdate` from the UI and to try the
  companion **Live Activity** payload fields
  (https://companion.home-assistant.io/docs/notifications/live-activities/).

  Actions: **Trigger** starts the activity, **+10** bumps the progress bar,
  **Clear** ends it, **All fields** sends every documented field at once. The
  **Sticky / Alert once / Silent / Chrono** buttons toggle that field and re-send
  (Sticky keeps the card up when you tap it); **Color** cycles the tint.

  The badge shows the current progress, the active toggles, the color, and the
  last result (`sent N`, `not connected`, ...). Fields go to `person.mog`'s
  companion device (Android 16+ / iOS); the platform-specific ones (Silent, icon
  color, background/text colors, url, relevance) only take effect on their
  platform. `title`/`message` are top-level; every other field rides in the
  notify service's `data` dict (handled by the core).

   **Android note:** the Android companion app currently has broken
   *live-notification icon* support (the icon does not render); a workaround
   exists — https://github.com/home-assistant/android/issues/5758#issuecomment-3297763341.

   One module plays both roles (the `handle/1` handler fed by the buttons, and its
   display node via `handle/2`), following the `counter` example. No wires.
   """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState
  alias HomeElixir.HA.LiveUpdate

  @person "mog"
  @tag "he_liveupdate"
  @colors ["#1e88e5", "#43a047", "#e53935", "#8e24aa", "#fb8c00"]

  # ---- actions ----

  def handle(%{payload: "trigger"}) do
    FlowState.put(:started_at, now_ms())
    :ok = FlowState.put(:status, describe(send(0)))
    0
  end

  def handle(%{payload: "plus"}) do
    p = FlowState.update(:progress, fn c -> min((c || 0) + 10, 100) end, 10)
    :ok = FlowState.put(:status, describe(send(p)))
    p
  end

  def handle(%{payload: "clear"}) do
    :ok = FlowState.put(:status, describe(LiveUpdate.dismiss(@person, @tag)))
    0
  end

  def handle(%{payload: "all"}) do
    :ok = FlowState.put(:status, describe(LiveUpdate.update(@person, @tag, all_fields())))
    0
  end

  def handle(%{payload: key}) when key in ["sticky", "once", "silent", "chrono"] do
    toggle(String.to_atom(key))
  end

  def handle(%{payload: "color"}) do
    cur = opts().color
    next = Enum.at(@colors, rem(index_of(@colors, cur) + 1, length(@colors)))
    FlowState.put(:color, next)
    :ok = FlowState.put(:status, describe(send(FlowState.get(:progress, 0))))
    0
  end

  # ---- display mirror ----

  @impl true
  def init(_), do: %{state: display()}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: display()}}

  node("trigger", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Trigger", payload: "trigger"})
  node("plus", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "+10", payload: "plus"})
  node("clear", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Clear", payload: "clear"})
  node("sticky", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Sticky", payload: "sticky"})
  node("once", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Alert once", payload: "once"})
  node("silent", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Silent", payload: "silent"})
  node("chrono", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Chrono", payload: "chrono"})
  node("color", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Color", payload: "color"})
  node("all", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "All fields", payload: "all"})
  node("badge", __MODULE__, ui: %{type: "state", label: "LiveUpdate"})

  # ---- helpers ----

  defp toggle(key) do
    FlowState.put(key, not opts()[key])
    :ok = FlowState.put(:status, describe(send(FlowState.get(:progress, 0))))
    0
  end

  defp opts do
    %{
      sticky: FlowState.get(:sticky, true) || false,
      once: FlowState.get(:once) || false,
      silent: FlowState.get(:silent) || false,
      chrono: FlowState.get(:chrono, true) || false,
      color: FlowState.get(:color) || hd(@colors)
    }
  end

  defp send(progress) do
    o = opts()

    LiveUpdate.update(@person, @tag, %{
      title: "LiveUpdate lab",
      message: "sticky #{b(o.sticky)} once #{b(o.once)} silent #{b(o.silent)} chrono #{b(o.chrono)}",
      critical_text: "lab",
      progress: progress,
      progress_max: 100,
      chronometer: o.chrono,
      when: when_ref(),
      notification_icon: "mdi:water",
      notification_icon_color: o.color,
      color: o.color,
      silent: o.silent,
      alert_once: o.once,
      sticky: o.sticky
    })
  end

  # Every documented field, to see them all at once.
  defp all_fields do
    %{
      title: "LiveUpdate · all fields",
      message: "every documented field active",
      critical_text: "5 min",
      progress: FlowState.get(:progress, 0),
      progress_max: 100,
      chronometer: true,
      when: when_ref(),
      notification_icon: "mdi:home-assistant",
      notification_icon_color: "#03A9F4",
      color: "#1e88e5",
      silent: false,
      url: "/lovelace/0",
      background_color: "#101820",
      text_color: "#FFFFFF",
      progress_bar_color: "#4CAF50",
      progress_bar_direction: "increasing",
      relevance_score: 0.9,
      alert_once: true,
      sticky: true
    }
  end

  defp display do
    o = opts()

    "p#{FlowState.get(:progress, 0)} s#{b(o.sticky)} o#{b(o.once)} t#{b(o.silent)} c#{b(o.chrono)} #{o.color} · #{FlowState.get(:status, "idle")}"
  end

  defp when_ref, do: div(FlowState.get(:started_at) || now_ms(), 1000)
  defp now_ms, do: :os.system_time(:millisecond)
  defp b(true), do: "✓"
  defp b(false), do: "✗"
  defp index_of(list, item), do: Enum.find_index(list, &(&1 == item)) || 0

  defp describe({:ok, n}), do: "sent #{n}"
  defp describe({:error, :not_connected}), do: "not connected"
  defp describe({:error, :person_not_found}), do: "person not found"
  defp describe({:error, :no_devices}), do: "no devices"
  defp describe({:error, :ha_timeout}), do: "ha timeout"
end
