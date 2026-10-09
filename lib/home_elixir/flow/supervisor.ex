defmodule HomeElixir.Flow.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link({flow_key, flow}), do: Supervisor.start_link(__MODULE__, {flow_key, flow})

  @impl true
  def init({flow_key, flow}) do
    children =
      for {node_id, {handler, config}} <- flow.nodes do
        targets = for {from, to} <- flow.wires, from == node_id, do: to
        {HomeElixir.Flow.Node, {flow_key, node_id, handler, config, targets}}
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
