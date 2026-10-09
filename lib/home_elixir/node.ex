defmodule HomeElixir.Node do
  @moduledoc """
  Behaviour for flow nodes.

  `handle/2` turns one incoming message into a list of output messages; the
  engine currently forwards output index 0 only (multi-output is a later add).
  `init/1` is optional — a node that does not define it starts with state `nil`.

  `trigger/2` is optional for source/in nodes: it is called with an external
  event (e.g. `{:ha_event, ref, event}`) so the node can emit messages without
  an input.
  """

  @type msg :: HomeElixir.Msg.t()
  @type state :: term()
  @type outputs :: [msg | nil]

  @callback handle(msg, state) :: {outputs, state}
  @callback init(config :: term()) :: state
  @callback trigger(event :: term(), state) :: {outputs, state}

  @optional_callbacks init: 1, trigger: 2
end
