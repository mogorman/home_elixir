defmodule HomeElixir.Nodes.Counter do
  @moduledoc """
  A FlowState-backed counter that keeps its value in local node state and mirrors
  it to Mnesia, so a `ui: %{type: "state"}` badge is always in sync (no timer).

  On `init` it syncs its local value from Mnesia (survives reloads/restarts). On
  each inbound message it updates the local state and Mnesia together, so they
  never drift. The ambient flow is already set by the node engine, so it targets
  this flow's own FlowState.

  Inbound `payload` selects the operation:
    "inc"   -> +1
    "dec"   -> -1
    "set"   -> reset to `default`
    "clear" -> delete the key (value becomes the read default)
  Anything else is ignored.

  Config:
    * `key` — the FlowState key (required)
    * `default` — initial value and reset target (default `0`)

      node("count", HomeElixir.Nodes.Counter, key: :count, default: 0,
           ui: %{type: "state", label: "Count"})
  """
  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  @impl true
  # Sync local state from Mnesia on start.
  def init(config) do
    key = Map.fetch!(config, :key)
    default = Map.get(config, :default, 0)
    %{key: key, default: default, state: FlowState.get(key, default)}
  end

  @impl true
  def handle(%{payload: op}, state), do: op(op, state)
  def handle(_msg, state), do: {[nil], state}

  # ---- ops: each persists to Mnesia AND updates local state, in order, so they
  # stay in sync ----

  defp op("inc", state), do: set(state, current(state) + 1)
  defp op("dec", state), do: set(state, current(state) - 1)
  defp op("set", state), do: set(state, state.default)

  defp op("clear", state) do
    FlowState.delete(state.key)
    {[nil], %{state | state: nil}}
  end

  defp op(_other, state), do: {[nil], state}

  defp current(state), do: state.state || state.default

  defp set(state, value) do
    FlowState.put(state.key, value)
    {[nil], %{state | state: value}}
  end
end
