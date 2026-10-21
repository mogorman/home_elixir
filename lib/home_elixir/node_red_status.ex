defmodule HomeElixir.NodeRedStatus do
  @moduledoc """
  Tracks whether the Node-RED Companion integration is installed in Home
  Assistant. Probed once at startup (and re-checkable on demand from the admin
  page).

  Status is three-state:

    * `:loaded` — the integration is added & set up (its `nodered/version`
      websocket command is registered, which only happens once a config entry
      is loaded)
    * `:absent` — HA is reachable but the integration is not added/set up
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

  @doc "The detected integration version, when present (`nil` otherwise)."
  def version do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :version)
      _ -> nil
    end
  end

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
    {:ok, %{status: :unknown, version: nil, retries: 0}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:version, _from, state), do: {:reply, state.version, state}

  def handle_call(:recheck, _from, state) do
    {s, v} = probe_once()
    {:reply, s, %{state | status: s, version: v}}
  end

  @impl true
  # One-time startup probe: wait for the HA client to be connected, then probe
  # once. `:unknown` retries (the client is still coming up); `:loaded`/`:absent`
  # and retry exhaustion lock the status for the rest of this run.
  def handle_info(:probe, state) do
    {s, v} = probe_once()

    if s == :unknown and state.retries < @max_retries do
      Process.send_after(self(), :probe, @retry_ms)
      {:noreply, %{state | retries: state.retries + 1}}
    else
      {:noreply, %{state | status: s, version: v}}
    end
  end

  # A single presence check. Returns `{status, version}` where `version` is the
  # integration's reported version when `:loaded`, else `nil`. `:unknown` whenever
  # we can't tell (no client, not connected, or the probe failed/timed out).
  defp probe_once do
    case HA.client() do
      nil ->
        {:unknown, nil}

      client ->
        if HA.Client.status(client) != :connected do
          {:unknown, nil}
        else
          # `nodered/version` is registered (alongside `nodered/discovery` and
          # `nodered/entity`) only once a config entry is set up, so a version
          # reply means the integration is actually added & functional — not just
          # that its files are installed. Unknown command => not added/set up.
          try do
            case HA.Client.call(client, "nodered/version", %{}, 1_500) do
              version when is_binary(version) -> {:loaded, version}
              {:error, %{code: "unknown_command"}} -> {:absent, nil}
              _ -> {:unknown, nil}
            end
          rescue
            _ -> {:unknown, nil}
          end
        end
    end
  end
end
