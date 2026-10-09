defmodule HomeElixir.Nodes.StateChanged do
  @moduledoc """
  Source node: emits a message when a Home Assistant entity's state changes.

  Config:
    * `entity_id` — optional; emit only for this entity. Omit for all entities.

  The emitted message has `payload` = the new state, `topic` = the entity id,
  and `data` = `%{entity_id:, old_state:, new_state:}`.
  """
  @behaviour HomeElixir.Node

  alias HomeElixir.{HA, Msg}

  @impl true
  def init(config) do
    ref =
      case HA.client() do
        nil ->
          nil

        client ->
          HA.Client.subscribe_events(client, "state_changed", self())
      end

    %{ref: ref, entity_id: config[:entity_id]}
  end

  @impl true
  def handle(_msg, state), do: {[nil], state}

  @impl true
  def trigger({:ha_event, _ref, event}, state) do
    entity_id = Map.get(event, "entity_id")

    if state.entity_id in [nil, entity_id] do
      msg = %Msg{
        payload: Map.get(event, "new_state"),
        topic: entity_id,
        data: %{
          entity_id: entity_id,
          old_state: Map.get(event, "old_state"),
          new_state: Map.get(event, "new_state")
        }
      }

      {[msg], state}
    else
      {[nil], state}
    end
  end

  def trigger(_other, state), do: {[nil], state}
end
