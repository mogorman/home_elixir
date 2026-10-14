defmodule HomeElixir.LogHandler do
  @moduledoc false
  @behaviour :logger_handler

  # Tag lines emitted by a flow's processes (see the :logger process metadata set
  # in HomeElixir.Flow.Node.init) with the flow name; the web flow log filters
  # on this "[name]" text.
  @impl true
  def log(%{level: level, msg: {:string, text}} = event, state) do
    meta = Map.get(event, :meta) || Map.get(event, :metadata) || %{}

    text =
      case meta do
        %{flow: flow} when is_binary(flow) -> "[#{flow}] #{text}"
        _ -> text
      end

    if log = Process.whereis(HomeElixir.Log), do: GenServer.cast(log, {:line, level, text})
    {:ok, state}
  end

  @impl true
  def log(_event, state), do: {:ok, state}
end
