defmodule HomeElixir.Nodered do
  @moduledoc """
  Helpers for managing Node-RED-integration entities from Elixir.
  """

  alias HomeElixir.HA

  @doc """
  Force-remove a device previously presented via `HomeElixir.Nodes.Device`.

  Sends a `nodered/discovery` frame with `remove: true`, deleting the entity
  from Home Assistant. Use after unloading a flow (or to clean up a leftover
  device) — unloading a flow leaves the entity in place (it goes unavailable
  when this service's connection drops).
  """
  def remove(server_id, node_id, component \\ "switch") do
    case HA.client() do
      nil ->
        :ok

      client ->
        HA.Client.call(client, "nodered/discovery", %{
          component: component,
          server_id: server_id,
          node_id: node_id,
          remove: true
        })
    end
  end
end
