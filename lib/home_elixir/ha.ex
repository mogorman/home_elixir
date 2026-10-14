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

  @doc "The configured HA endpoint (env `HA_URL` or config `:ha_url`), or `nil`."
  def config_url do
    System.get_env("HA_URL") || Application.get_env(:home_elixir, :ha_url)
  end

  @doc "The configured HA auth token (env `HA_TOKEN` or config `:ha_token`), or `nil`."
  def token do
    System.get_env("HA_TOKEN") || Application.get_env(:home_elixir, :ha_token)
  end

  @doc """
  The HA REST base URL (`scheme://host[:port]`) for HTTP API calls, derived from
  the configured endpoint (which may be a `wss://`/`ws://` WebSocket URL).
  """
  def rest_base do
    config_url()
    |> String.replace_prefix("wss://", "https://")
    |> String.replace_prefix("ws://", "http://")
    |> URI.parse()
    |> then(&"#{&1.scheme}://#{&1.host}#{if &1.port, do: ":#{&1.port}", else: ""}")
  end
end
