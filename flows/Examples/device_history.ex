defmodule HomeElixir.Flows.Examples.DeviceHistory do
  @moduledoc """
  Example: get the history of every entity on a device.

  `device_id` and `range` are editable in the UI (same meaning as
  `EntityHistory`). The button/cron fetch `HomeElixir.HA.device_history/2` and
  render the rows as a table.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @default_device "bd6e21878a14c8461c3635d8ab83f96e"

  def setup do
    HomeElixir.Config.seed(%{device_id: @default_device, range: 1})
  end

  def handle(%{payload: "refresh"}) do
    case HomeElixir.HA.device_history(device(), range()) do
      {:ok, states} ->
        FlowState.put(:rows, %{cols: ["Entity", "State", "Changed"], rows: rows(states)})

      {:error, reason} ->
        FlowState.put(:rows, %{cols: ["Error"], rows: [[inspect(reason)]]})
    end
  end

  defp rows(states) do
    for s <- states, do: [s["entity_id"], s["state"], changed(s["last_changed"])]
  end

  defp changed(nil), do: nil
  defp changed(ts) when is_binary(ts), do: ts |> String.slice(0, 19) |> String.replace("T", " ")

  @impl true
  def init(_), do: %{state: FlowState.get(:rows)}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:rows)}}

  defp device, do: HomeElixir.Config.get(:device_id, @default_device)
  defp range, do: HomeElixir.Config.get(:range, 1)

  node("refresh", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Refresh", payload: "refresh"})

  node("tick", HomeElixir.Nodes.Schedule, cron: "*/2 * * * *", payload: "refresh")

  node("rows", __MODULE__, ui: %{type: "table", label: "Device history"})
end
