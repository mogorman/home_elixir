defmodule HomeElixir.Node do
  @moduledoc """
  Behaviour for flow nodes.

  `handle/2` turns one incoming message into a list of output messages; the
  engine currently forwards output index 0 only (multi-output is a later add).
  `init/1` is optional — a node that does not define it starts with state `nil`.
  """

  @type msg :: HomeElixir.Msg.t()
  @type state :: term()
  @type outputs :: [msg | nil]

  @callback handle(msg, state) :: {outputs, state}
  @callback init(config :: term()) :: state
end
