defmodule HomeElixir.Flows.Examples.WatchAll do
  @moduledoc """
  Example read-only flow: log every Home Assistant state change.

  Watch the app log; each change appears as
  `ha-flow <entity_id> payload=<new_state> data=<...>`.
  """
  use HomeElixir.Flow

  node("changes", HomeElixir.Nodes.StateChanged)
  node("log", HomeElixir.Nodes.Logger)
  wire("changes", "log")
end
