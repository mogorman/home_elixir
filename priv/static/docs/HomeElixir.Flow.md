# `HomeElixir.Flow`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/flow.ex#L1)

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*
