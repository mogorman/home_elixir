defmodule HomeElixir.Nodes.Sink do
  @moduledoc """
  Records every incoming message (most recent first). Useful as a flow endpoint
  and for tests; read it back via `HomeElixir.Registry.node_state/2`.
  """
  @behaviour HomeElixir.Node

  @impl true
  def init(_config), do: []

  @impl true
  def handle(msg, messages), do: {[], [msg | messages]}
end
