defmodule HomeElixir.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Start TLS before anything opens a wss:// connection. Mint uses :ssl but
    # does not declare it (it also works plain), and a prod release only starts
    # the apps it is told to — so :ssl would be bundled-but-not-running and the
    # first TLS handshake would raise :ssl_not_started. Cheap to start always.
    Application.ensure_all_started(:ssl)

    # Start Mnesia + the flow-state table before any flow loads, so flows can
    # persist state from their first event.
    HomeElixir.FlowState.start()

    # Config table (layered flow/global config, seeded in flow `setup/0`).
    HomeElixir.Config.start()

    children =
      [
        {HomeElixir.UI.Hub, []},
        {Registry, keys: :unique, name: HomeElixir.NodeLookup},
        {HomeElixir.Registry, []},
        {HomeElixir.FlowStore, []},
        {HomeElixir.Log, []},
        {HomeElixir.Auth, []},
        {HomeElixir.HA.PendingLogins, []}
      ] ++ ha_client_child() ++ flows_ha_child() ++ web_child()

    opts = [strategy: :one_for_one, name: HomeElixir.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    :logger.add_handler(:home_elixir_log, HomeElixir.LogHandler, %{})

    # Restore the loaded/unloaded state from the previous run (Mnesia flow-state
    # DB); broken flows are logged + skipped.
    if Application.get_env(:home_elixir, :restore_flows, false) do
      # Wipe the dep cache if the flows' declared deps changed since last boot,
      # so the build matches exactly what's needed (no growth, no cross-eviction).
      HomeElixir.Dep.reset_if_stale()
      HomeElixir.FlowStore.restore()
    end

    {:ok, pid}
  end

  # Starts the shared, named HA client when HA is configured (and auto-start is
  # enabled). Without HA_URL/HA_TOKEN the app runs flows that don't need HA.
  defp ha_client_child do
    auto = Application.get_env(:home_elixir, :auto_start_ha, true)
    url = HomeElixir.HA.config_url()
    token = HomeElixir.HA.token()

    if auto && url && token do
      [
        {HomeElixir.HA.Client, [name: HomeElixir.HA.client_name(), url: url, token: token]}
      ]
    else
      []
    end
  end

  # The HA "Flows" switcher (one switch per flow). Started after the HA client
  # so its name is registered; disabled in tests (an isolated instance runs there).
  defp flows_ha_child do
    if Application.get_env(:home_elixir, :start_flows_ha, true),
      do: [HomeElixir.FlowsHA],
      else: []
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
          plug: HomeElixir.AuthGuard,
          port: String.to_integer(port),
          ip: parse_ip(host)
        )
      ]
    else
      []
    end
  end

  @impl true
  def terminate(_type, _state) do
    HomeElixir.FlowState.stop()
  end

  defp parse_ip(host) do
    host |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end
end
