defmodule HomeElixir.Flow.Node do
  @moduledoc false
  @behaviour GenServer

  require Logger

  def start_link({flow_key, node_id, handler, config, out_targets}) do
    GenServer.start_link(__MODULE__, {flow_key, node_id, handler, config, out_targets})
  end

  @doc false
  def child_spec({flow_key, node_id, _handler, _config, _targets} = arg) do
    %{id: {__MODULE__, flow_key, node_id}, start: {__MODULE__, :start_link, [arg]}}
  end

  @impl true
  def init({flow_key, node_id, handler, config, out_targets}) do
    {:ok, _} = Registry.register(HomeElixir.NodeLookup, {flow_key, node_id}, nil)
    Code.ensure_loaded(handler)

    node_state =
      if function_exported?(handler, :init, 1), do: handler.init(config), else: nil

    state = %{
      flow_key: flow_key,
      node_id: node_id,
      handler: handler,
      out_targets: out_targets,
      routing: [],
      routed?: false,
      node_state: node_state
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:route, state) do
    routing =
      for target <- state.out_targets, into: [] do
        case Registry.lookup(HomeElixir.NodeLookup, {state.flow_key, target}) do
          [{pid, _}] -> pid
          _ -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    {:noreply, %{state | routing: routing, routed?: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:msg, msg}, state) do
    process_msg(msg, state)
  end

  @impl true
  def handle_call(:__state__, _from, state), do: {:reply, state.node_state, state}

  defp process_msg(msg, %{routed?: true} = state) do
    {outputs, node_state} = state.handler.handle(msg, state.node_state)

    case Enum.at(outputs, 0) do
      nil -> :ok
      out -> Enum.each(state.routing, fn pid -> GenServer.cast(pid, {:msg, out}) end)
    end

    {:noreply, %{state | node_state: node_state}}
  end

  defp process_msg(_msg, state) do
    Logger.debug("dropped message before routing: #{state.node_id}")
    {:noreply, state}
  end
end
