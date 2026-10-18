defmodule HomeElixir.Flows.Examples.DeviceStates do
  @moduledoc """
  Example: get the current states of every entity on a device.

  `device_id` is editable in the UI. A web button and a 2-minute cron fetch
  `HomeElixir.HA.device_states/1` and render the entities as a table.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @default_device "27ba9e76e68fa71f85fe1d63d78071c6"

  def setup do
    HomeElixir.Config.seed(%{device_id: @default_device})
  end

  def handle(%{payload: "refresh"}) do
    case HomeElixir.HA.device_states(device()) do
      {:ok, states} ->
        FlowState.put(:rows, %{cols: ["Entity", "State", "Unit"], rows: rows(states)})

      {:error, reason} ->
        FlowState.put(:rows, %{cols: ["Error"], rows: [[inspect(reason)]]})
    end
  end

  defp rows(states) do
    for s <- states do
      attrs = s["attributes"] || %{}
      [s["entity_id"], s["state"], Map.get(attrs, "unit_of_measurement")]
    end
  end

  @impl true
  def init(_), do: %{state: FlowState.get(:rows)}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:rows)}}

  defp device, do: HomeElixir.Config.get(:device_id, @default_device)

  node("refresh", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Refresh", payload: "refresh"})

  node("tick", HomeElixir.Nodes.Schedule, cron: "*/2 * * * *", payload: "refresh")

  node("rows", __MODULE__, ui: %{type: "table", label: "Device states"})
end
