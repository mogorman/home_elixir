defmodule HomeElixir.Registry do
  @moduledoc """
  Loads and unloads flows and tracks which are running.

  A *flow* is an Elixir module using `HomeElixir.Flow`. Loading it spawns a
  supervised process per node and wires them together; unloading tears it down.
  """
  use Supervisor

  @flow_sup :home_elixir_flow_sup
  @flow_ets :home_elixir_flows

  def start_link([]), do: Supervisor.start_link(__MODULE__, [])

  # ---- lifecycle ----

  @doc "Load a flow module. Returns `{:ok, pid}` or `{:error, reason}`."
  def load(flow_key) do
    if loaded?(flow_key) do
      {:error, :already_loaded}
    else
      flow = flow_key.__flow__()

      spec = %{
        id: flow_key,
        start: {HomeElixir.Flow.Supervisor, :start_link, [{flow_key, flow}]},
        type: :supervisor
      }

      case DynamicSupervisor.start_child(@flow_sup, spec) do
        {:ok, pid} ->
          :ets.insert(@flow_ets, {flow_key, pid})
          route_flow(flow_key, flow)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Unload a flow module (stops all its nodes)."
  def unload(flow_key) do
    case :ets.lookup(@flow_ets, flow_key) do
      [{_, pid}] ->
        DynamicSupervisor.terminate_child(@flow_sup, pid)
        :ets.delete(@flow_ets, flow_key)
        :ok

      [] ->
        :ok
    end
  end

  @doc "All currently loaded flow modules."
  def list do
    for {flow_key, _} <- :ets.tab2list(@flow_ets), do: flow_key
  end

  @doc """
  UI elements declared by loaded flows. Collects nodes whose config has a
  `ui:` map and returns `[%{module, node_id, ui}]`.
  """
  def ui_elements do
    list()
    |> Enum.flat_map(fn mod ->
      mod.__flow__()
      |> Map.get(:nodes, [])
      |> Enum.map(fn {node_id, {_handler, config}} ->
        case Map.get(config, :ui) do
          %{type: _type} = ui -> %{module: mod, node_id: node_id, ui: ui}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  @doc "Whether a flow module is loaded."
  def loaded?(flow_key), do: :ets.member(@flow_ets, flow_key)

  # ---- runtime helpers ----

  @doc "Cast a message into a node of a loaded flow."
  def send_msg(flow_key, node_id, msg) do
    case Registry.lookup(HomeElixir.NodeLookup, {flow_key, node_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:msg, msg})
      _ -> :error
    end
  end

  @doc "Read a node's internal state (for tests / debug)."
  def node_state(flow_key, node_id) do
    case Registry.lookup(HomeElixir.NodeLookup, {flow_key, node_id}) do
      [{pid, _}] -> GenServer.call(pid, :__state__)
      _ -> nil
    end
  end

  defp route_flow(flow_key, flow) do
    for {node_id, _spec} <- flow.nodes do
      case Registry.lookup(HomeElixir.NodeLookup, {flow_key, node_id}) do
        [{pid, _}] -> send(pid, :route)
        _ -> :ok
      end
    end
  end

  # ---- supervisor ----

  @impl true
  def init([]) do
    :ets.new(@flow_ets, [:set, :named_table, :public, read_concurrency: true])

    children = [
      {DynamicSupervisor, name: @flow_sup, strategy: :one_for_one, max_children: :infinity}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
