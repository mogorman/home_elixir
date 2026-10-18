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
    HomeElixir.FlowState.set_flow(flow_key)
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
      node_state: node_state,
      state_ui?: ui_state?(config),
      flow_name: to_string(flow_key) |> String.split(".") |> List.last() |> Macro.underscore(),
      last_hit: nil
    }

    # Tag every log line from this process with the flow's name; the web flow
    # log filters lines on the "[name]" text (see HomeElixir.LogHandler).
    # ponytail: derived from the module name, which matches the flow file's
    # last path segment for the standard naming; a flow whose file name diverges
    # from its module name would tag under the module name.
    :logger.set_process_metadata(%{flow: state.flow_name})

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

  # External events (e.g. HA state changes) drive source nodes via trigger/2.
  def handle_info(event, %{routed?: true} = state) do
    if function_exported?(state.handler, :trigger, 2) do
      state = record_trigger(state)
      {outputs, node_state} = state.handler.trigger(event, state.node_state)
      state = %{state | node_state: node_state}
      push_ui(state)
      {:noreply, route_outputs(outputs, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:msg, msg}, %{routed?: true} = state) do
    state = record_trigger(state)
    msg = with_flow(msg, state.flow_name)
    {outputs, node_state} = state.handler.handle(msg, state.node_state)
    state = %{state | node_state: node_state}
    push_ui(state)
    {:noreply, route_outputs(outputs, state)}
  end

  def handle_cast({:msg, _msg}, state) do
    Logger.debug("dropped message before routing: #{state.node_id}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:__state__, _from, state), do: {:reply, state.node_state, state}

  defp route_outputs(outputs, state) do
    case Enum.at(outputs, 0) do
      nil ->
        state

      out ->
        out = with_flow(out, state.flow_name)
        Enum.each(state.routing, fn pid -> GenServer.cast(pid, {:msg, out}) end)
        state
    end
  end

  # Record that this flow was triggered, at most once per second per node, so a
  # bursty flow can't hammer the Mnesia write path on every message.
  defp record_trigger(state) do
    now = System.system_time(:millisecond)

    if is_nil(state.last_hit) or now - state.last_hit >= 1_000 do
      HomeElixir.FlowState.record_triggered(state.flow_key)
      %{state | last_hit: now}
    else
      state
    end
  end

  # Tag a message with its flow's short name so logs/UI can attribute it.
  defp with_flow(%HomeElixir.Msg{} = msg, name), do: %{msg | data: Map.put(msg.data, :flow, name)}
  defp with_flow(msg, _name), do: msg

  # True when this node backs a `ui: %{type: "state"}` badge, an `"image"`, or a
  # `"table"`.
  defp ui_state?(config) do
    match?(%{type: "state"}, config[:ui]) or
      match?(%{type: "image"}, config[:ui]) or match?(%{type: "table"}, config[:ui])
  end

  # Push this node's display value to the web UI when it changes (state badges only).
  defp push_ui(%{state_ui?: true, flow_name: flow, node_id: node_id, node_state: ns}) do
    value = if is_map(ns), do: Map.get(ns, :state), else: nil
    HomeElixir.UI.Hub.push(:state, %{flow: flow, node: node_id, value: value})
  end

  defp push_ui(_), do: :ok
end
