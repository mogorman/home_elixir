defmodule HomeElixir.Nodes.Logger do
  @moduledoc """
  Logs each incoming message and produces no output. A debug/observation node
  (the Node-RED `debug` equivalent), useful as a flow endpoint and for e2e.
  """
  @behaviour HomeElixir.Node

  require Logger

  @impl true
  def handle(%HomeElixir.Msg{payload: payload, topic: topic, data: data}, _state) do
    rest = Map.delete(data, :flow)
    Logger.info("ha-flow #{topic || "-"} payload=#{inspect(payload)} data=#{inspect(rest)}")
    {[nil], nil}
  end
end
