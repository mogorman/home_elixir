defmodule HomeElixir.LogHandler do
  @moduledoc false
  @behaviour :logger_handler

  @impl true
  def log(%{level: level, msg: {:string, text}}, state) do
    if log = Process.whereis(HomeElixir.Log), do: GenServer.cast(log, {:line, level, text})
    {:ok, state}
  end

  @impl true
  def log(_event, state), do: {:ok, state}
end
