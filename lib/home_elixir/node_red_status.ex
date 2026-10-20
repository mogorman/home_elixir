defmodule HomeElixir.NodeRedStatus do
  @moduledoc """
  Tracks whether the Node-RED Companion integration is installed in Home
  Assistant. Probed once at startup (and re-checkable on demand from the admin
  page).

  Status is three-state:

    * `:loaded` — the Node-RED Companion integration is installed/enabled
      (it loads as the `nodered` component)
    * `:absent` — HA is reachable but the integration is not installed/enabled
    * `:unknown` — can't tell (no HA client, not connected yet, or a probe error)

  Only `:absent` changes behavior (the flow→Node-RED sync stops and `device`
  nodes go inert). `:unknown` keeps existing behavior so a slow or absent HA
  connection at boot never raises a false "missing" warning.
  """
  use GenServer

  alias HomeElixir.HA

  @retry_ms 400
  # ~12s window for the HA client to come up after boot before giving up.
  @max_retries 30

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current status: `:loaded`, `:absent`, or `:unknown`."
  def status do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> :unknown
    end
  end

  @doc "True when the Node-RED integration is present."
  def present?, do: status() == :loaded

  @doc "Re-run the probe now and return the new status."
  def recheck do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :recheck)
      _ -> :unknown
    end
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :probe, @retry_ms)
    {:ok, %{status: :unknown, retries: 0}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:recheck, _from, state) do
    s = probe_once()
    {:reply, s, %{state | status: s}}
  end

  @impl true
  # One-time startup probe: wait for the HA client to be connected, then probe
  # once. `:unknown` retries (the client is still coming up); `:loaded`/`:absent`
  # and retry exhaustion lock the status for the rest of this run.
  def handle_info(:probe, state) do
    case probe_once() do
      :unknown when state.retries < @max_retries ->
        Process.send_after(self(), :probe, @retry_ms)
        {:noreply, %{state | retries: state.retries + 1}}

      s ->
        {:noreply, %{state | status: s}}
    end
  end

  # A single presence check. `:unknown` whenever we can't tell (no client, not
  # connected, or the probe itself failed/timed out).
  defp probe_once do
    case HA.client() do
      nil ->
        :unknown

      client ->
        if HA.Client.status(client) != :connected do
          :unknown
        else
          case HA.Client.call(client, "get_config", %{}, 1_500) do
            %{} = cfg ->
              comps = Map.get(cfg, "components", [])
              # The integration loads as the `nodered` component (plus `nodered.*`).
              # Its presence means it is installed and enabled.
              present = Enum.any?(comps, &(&1 == "nodered" or String.starts_with?(&1, "nodered.")))
              if present, do: :loaded, else: :absent

            _ ->
              :unknown
          end
        end
    end
  end
end
