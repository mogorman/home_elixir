defmodule HomeElixir.Flow do
  @moduledoc """
  Declare a flow as an Elixir module.

     defmodule Flows.Kitchen do
       use HomeElixir.Flow

       def exclaim(m), do: %{m | payload: m.payload <> "!"}

       node("in",  HomeElixir.Nodes.Inject, payload: "hi")
       node("f",   HomeElixir.Nodes.Function, fun: &__MODULE__.exclaim/1)
       node("out", HomeElixir.Nodes.Sink)
       wire("in", "f")
       wire("f", "out")
     end

  `__flow__` returns the declared nodes and wires; `HomeElixir.Registry` turns
  that into a supervised process tree. Node config must be data (or a remote
  function like `&Mod.fun/1`); transforms are plain functions on the flow.

  A flow may also define `setup/0`. It runs once when the flow is loaded,
  before any node starts — use it to install external deps at load time
  (Livebook-style), without editing `mix.exs`:

     def setup, do: HomeElixir.Dep.install([{:timex, "~> 3.7"}])

  A flow may instead define `handle/1` (a "handler flow"). It is wired to a
  Home Assistant `state_changed` source automatically. Its return value is
  forwarded to the nodes wired after `__he_handle__` — so state-changing
  clauses return a value (the FlowState op's result does) to wake display
  nodes, and unmatched input falls through the catch-all, which returns nil
  and is dropped:

     defmodule Flows.DoorWatch do
       use HomeElixir.Flow
       def handle(%{topic: "sensor.front_door", payload: "open"}) do
         ... # do work
       end
     end

  The catch-all clause is added for you; write only the clauses you need.

  Flows may also persist state between runs via `HomeElixir.FlowState` (Mnesia;
  survives reloads and restarts). The flow's own module is the implicit key, so
  flows can't collide:

      def handle(%{topic: "sensor.front_door", payload: "open"}),
        do: HomeElixir.FlowState.update(:count, &(&1 + 1), 0)
  """

  defmacro __using__(_opts) do
    quote do
      import HomeElixir.Flow.Macro
      Module.register_attribute(__MODULE__, :fe_nodes, accumulate: true)
      Module.register_attribute(__MODULE__, :fe_wires, accumulate: true)
      @before_compile HomeElixir.Flow
    end
  end

  defmacro __before_compile__(context) do
    if Module.defines?(context.module, {:handle, 1}, :def) do
      # A flow that defines handle/1 is a "handler flow": an HA state-change
      # source is wired to &handle/1 and its return is discarded. The injected
      # catch-all lets authors write only the clauses they care about.
      # ponytail: one unfiltered state_changed source feeds every handler, which
      # pattern-match — fine until a handler flow is hot; then give each handler
      # its own entity_id-filtered StateChanged source.
      handler_fun = quote do: &unquote(context.module).handle/1

      quote do
        # nil (not :ok): the handler's return feeds its output nodes, and nil
        # is dropped — so unmatched input wakes no display node.
        def handle(_), do: nil

        @doc false
        def __flow__ do
          # Source nodes with no outgoing wire feed the handler automatically
          # (buttons and cron schedules need no wiring).
          auto_in =
            for {id, {mod, _}} <- @fe_nodes,
                mod in [HomeElixir.Nodes.Inject, HomeElixir.Nodes.Schedule],
                not Enum.any?(@fe_wires, fn {f, _} -> f == id end),
                do: {id, "__he_handle__"}

          # Display nodes (state badges + images) with no incoming wire are fed
          # by the handler, so a display mirror needs no wiring.
          auto_out =
            for {id, {_mod, config}} <- @fe_nodes,
                is_map(config) and config[:ui][:type] in ["state", "image"],
                not Enum.any?(@fe_wires, fn {_, t} -> t == id end),
                do: {"__he_handle__", id}

          %{
            nodes:
              @fe_nodes ++
                [
                  {"__he_in__", {HomeElixir.Nodes.StateChanged, %{}}},
                  {"__he_handle__", {HomeElixir.Nodes.Function, %{fun: unquote(handler_fun)}}}
                ],
            wires: @fe_wires ++ auto_in ++ auto_out ++ [{"__he_in__", "__he_handle__"}]
          }
        end
      end
    else
      quote do
        @doc false
        def __flow__, do: %{nodes: @fe_nodes, wires: @fe_wires}
      end
    end
  end
end
