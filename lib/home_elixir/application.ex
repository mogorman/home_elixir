defmodule HomeElixir.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: HomeElixir.NodeLookup},
        {HomeElixir.Registry, []}
      ] ++ ha_client_child()

    opts = [strategy: :one_for_one, name: HomeElixir.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Starts the shared, named HA client when HA is configured (and auto-start is
  # enabled). Without HA_URL/HA_TOKEN the app runs flows that don't need HA.
  defp ha_client_child do
    auto = Application.get_env(:home_elixir, :auto_start_ha, true)
    url = System.get_env("HA_URL") || Application.get_env(:home_elixir, :ha_url)
    token = System.get_env("HA_TOKEN") || Application.get_env(:home_elixir, :ha_token)

    if auto && url && token do
      [
        {HomeElixir.HA.Client,
         [name: HomeElixir.HA.client_name(), url: url, token: token]}
      ]
    else
      []
    end
  end
end
