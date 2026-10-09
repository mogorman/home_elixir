defmodule HomeElixir.Log do
  @moduledoc """
  In-memory ring buffer of recent log lines, fed by `HomeElixir.LogHandler`.

  The web log page polls `lines/1` for entries newer than a given id, so the
  page grows as the app logs.
  """
  use GenServer

  @max 500

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return `[id, line]` entries with `id > since` (newest last)."
  def lines(since \\ 0), do: GenServer.call(__MODULE__, {:tail, since})

  def init(_), do: {:ok, %{lines: [], counter: 0}}

  def handle_cast({:line, level, text}, state) do
    id = state.counter + 1
    entry = {id, "#{level}  #{text}"}
    lines = push(state.lines, entry)
    {:noreply, %{state | counter: id, lines: lines}}
  end

  def handle_call({:tail, since}, _from, state) do
    {:reply, Enum.filter(state.lines, fn {id, _} -> id > since end), state}
  end

  defp push(lines, entry) do
    all = lines ++ [entry]
    if length(all) > @max, do: Enum.drop(all, length(all) - @max), else: all
  end
end
