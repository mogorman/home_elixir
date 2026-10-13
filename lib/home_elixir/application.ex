defmodule HomeElixir.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Start Mnesia + the flow-state table before any flow loads, so flows can
    # persist state from their first event.
    HomeElixir.FlowState.start()

    children =
      [
        {HomeElixir.UI.Hub, []},
        {Registry, keys: :unique, name: HomeElixir.NodeLookup},
        {HomeElixir.Registry, []},
        {HomeElixir.FlowStore, []},
        {HomeElixir.Log, []}
      ] ++ ha_client_child() ++ web_child()

    opts = [strategy: :one_for_one, name: HomeElixir.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    :logger.add_handler(:home_elixir_log, HomeElixir.LogHandler, %{})

    # Restore the loaded/unloaded state from the previous run (flows/.loaded);
    # broken flows are logged + skipped.
    if Application.get_env(:home_elixir, :restore_flows, false) do
      HomeElixir.FlowStore.restore()
    end

    {:ok, pid}
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

  # Serves the flow manager on `HOST:PORT` (defaults 127.0.0.1:4000; override
  # either via env var or the `:home_elixir, :web_host`/`:web_port` config).
  defp web_child do
    web_disabled? = System.get_env("HOME_ELIXIR_NO_WEB") == "1"

    if Application.get_env(:home_elixir, :start_web, true) and not web_disabled? do
      port =
        System.get_env("PORT") ||
          to_string(Application.get_env(:home_elixir, :web_port, 4000))

      host =
        System.get_env("HOST") || Application.get_env(:home_elixir, :web_host, "127.0.0.1")

      [
        Plug.Cowboy.child_spec(
          scheme: :http,
          plug: HomeElixir.Web,
          port: String.to_integer(port),
          ip: parse_ip(host)
        )
      ]
    else
      []
    end
  end

  defp parse_ip(host) do
    host |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end
end
