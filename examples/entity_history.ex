defmodule HomeElixir.Flows.Examples.EntityHistory do
  @moduledoc """
  Example: get the history of one entity's states.

   `entity_id` and `range` are editable in the UI. `range` is a number (look-back
   in hours) or a `{start, end}` date range; the button/cron fetch
   `HomeElixir.HA.entity_history/2` and render the rows as a table.
   """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @default_entity "sensor.fw2861_temperature"

  def setup do
    HomeElixir.Config.seed(%{entity_id: @default_entity, range: 1})
  end

  def handle(%{payload: "refresh"}) do
    case HomeElixir.HA.entity_history(entity(), range()) do
      {:ok, states} ->
        FlowState.put(:rows, %{cols: ["State", "Changed"], rows: rows(states)})

      {:error, reason} ->
        FlowState.put(:rows, %{cols: ["Error"], rows: [[inspect(reason)]]})
    end
  end

  defp rows(states) do
    for s <- states, do: [s["state"], changed(s["last_changed"])]
  end

  # HA returns "2026-10-18T13:29:45.123456+00:00"; trim to "YYYY-MM-DD HH:MM:SS".
  defp changed(nil), do: nil
  defp changed(ts) when is_binary(ts), do: ts |> String.slice(0, 19) |> String.replace("T", " ")

  @impl true
  def init(_), do: %{state: FlowState.get(:rows)}

  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:rows)}}

  defp entity, do: HomeElixir.Config.get(:entity_id, @default_entity)
  defp range, do: HomeElixir.Config.get(:range, 1)

  node("refresh", HomeElixir.Nodes.Inject,
    ui: %{type: "button", label: "Refresh", payload: "refresh"})

  node("tick", HomeElixir.Nodes.Schedule, cron: "*/2 * * * *", payload: "refresh")

  node("rows", __MODULE__, ui: %{type: "table", label: "History"})
end
