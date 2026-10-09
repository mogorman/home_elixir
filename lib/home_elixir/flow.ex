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
  """

  defmacro __using__(_opts) do
    quote do
      import HomeElixir.Flow.Macro
      Module.register_attribute(__MODULE__, :fe_nodes, accumulate: true)
      Module.register_attribute(__MODULE__, :fe_wires, accumulate: true)
      @before_compile HomeElixir.Flow
    end
  end

  defmacro __before_compile__(_context) do
    quote do
      @doc false
      def __flow__, do: %{nodes: @fe_nodes, wires: @fe_wires}
    end
  end
end
