defmodule HomeElixir.HA do
  @moduledoc """
  Access to the shared, named `HomeElixir.HA.Client`.

  Home Assistant uses a single WebSocket connection shared by every HA-aware
  node (mirroring Node-RED). The app starts one named client when
  `HA_URL`/`HA_TOKEN` are configured; nodes reach it through this module.
  """

  @client_name :home_elixir_ha_client

  @doc "The atom name of the shared client process."
  def client_name, do: @client_name

  @doc "The pid of the shared client, or `nil` if it is not running."
  def client, do: GenServer.whereis(@client_name)

  @doc "True when a shared client is running."
  def connected?, do: not is_nil(client())
end
