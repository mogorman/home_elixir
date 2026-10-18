defmodule HomeElixir.Flows.Examples.EntityState do
  @moduledoc """
  Example: get the current state of one entity.

  `entity_id` is editable in the UI (flow panel → config). A web button and a
  2-minute cron fetch `HomeElixir.HA.state/1` and show the result on the badge.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  def setup do
    HomeElixir.Config.seed(%{entity_id: "light.living_room_lamp_3"})
  end

  def handle(%{payload: "refresh"}) do
    case HomeElixir.HA.state(entity()) do
      {:ok, st} -> FlowState.put(:value, st["state"])
      {:error, reason} -> FlowState.put(:value, "error: #{inspect(reason)}")
    end
  end

  @impl true
  def init(_), do: %{state: FlowState.get(:value)}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:value)}}

  defp entity, do: HomeElixir.Config.get(:entity_id, "light.living_room_lamp_3")

  node("refresh", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Refresh", payload: "refresh"})

  node("tick", HomeElixir.Nodes.Schedule, cron: "*/2 * * * *", payload: "refresh")

  node("value", __MODULE__, ui: %{type: "state", label: "State"})
end
