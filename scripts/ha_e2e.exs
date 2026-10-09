# Live read-only e2e: connects to a real Home Assistant, loads a
# StateChanged -> Logger flow that watches every state change, and logs each
# one as it arrives. No services are called and no state is changed.
#
#   HA_URL=wss://ha.rldn.net/api/websocket HA_TOKEN=... \
#     mix run --no-halt scripts/ha_e2e.exs
#
# Watch the log; flip any entity in HA and its change appears as
# "ha-flow <entity_id> payload=<new_state> ...".

Application.ensure_all_started(:home_elixir)

alias HomeElixir.{HA, Registry}

defmodule E2EFlows.WatchAll do
  use HomeElixir.Flow

  node("sc", HomeElixir.Nodes.StateChanged)
  node("log", HomeElixir.Nodes.Logger)
  wire("sc", "log")
end

IO.puts("== HA read-only e2e ==")

# wait for the shared client to authenticate
deadline = System.monotonic_time(:second) + 30

Enum.reduce_while(1..300, :ok, fn _, _ ->
  if HA.Client.status(HA.client()) == :connected do
    {:halt, :ok}
  else
    if System.monotonic_time(:second) > deadline do
      IO.puts("client not connected after 30s; status=#{inspect(HA.Client.status(HA.client()))}")
      System.halt(1)
    end

    Process.sleep(100)
    {:cont, :ok}
  end
end)

IO.puts("connected. loading #{inspect(E2EFlows.WatchAll)} (watching all entities)...")
IO.puts("state changes will log as: ha-flow <entity_id> payload=<state> data=<...>")

{:ok, _} = Registry.load(E2EFlows.WatchAll)
IO.puts("loaded. Watching... (stop with Ctrl-C)")
