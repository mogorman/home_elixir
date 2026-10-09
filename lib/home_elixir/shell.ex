defmodule HomeElixir.Shell do
  @moduledoc """
  A live IEx-style evaluator attached to the running application.

  Runs real Elixir against the app's VM (all modules, flows, and the HA client
  are reachable). Supports multi-line input, the helper functions in
  `HomeElixir.ShellHelpers` (`h/1`, `ls/0`, `pwd/0`, `whereis/1`),
  and persists variable bindings between lines. Results are shown as values
  (`=> ...`); logged output goes to the log page.
  """
  use GenServer

  @continue "[continue]"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec eval(String.t()) :: String.t()
  def eval(line), do: GenServer.call(__MODULE__, {:eval, line})

  @spec reset() :: String.t()
  def reset(), do: GenServer.call(__MODULE__, :reset)

  def init(_), do: {:ok, %{bindings: [], counter: 1, pending: "", banner: banner()}}

  def handle_call({:eval, line}, _from, state) do
    source = state.pending <> line

    case complete?(source) do
      :incomplete ->
        {:reply, @continue, %{state | pending: source <> "\n"}}

      :complete ->
        do_eval(source, %{state | pending: ""})
    end
  end

  def handle_call(:reset, _from, _),
    do: {:reply, "shell reset.\n", %{bindings: [], counter: 1, pending: "", banner: banner()}}

  # ---- evaluation ----

  defp do_eval(source, state) do
    code = "require Logger\nimport HomeElixir.ShellHelpers\n" <> source
    n = state.counter

    try do
      {value, bindings} = Code.eval_string(code, state.bindings)
      {:reply, show_value(value), %{state | bindings: bindings, counter: n + 1}}
    rescue
      e -> {:reply, show_error(e), %{state | counter: n + 1}}
    catch
      kind, reason -> {:reply, "exception: #{kind} #{inspect(reason)}\n", %{state | counter: n + 1}}
    end
  end

  # Multi-line: accumulate until the input parses as a complete expression.
  defp complete?(source) do
    case Code.string_to_quoted(source) do
      {:ok, _} ->
        :complete

      {:error, {_meta, msg, _}} ->
        cond do
          String.starts_with?(msg, "missing terminator") -> :incomplete
          String.ends_with?(msg, "syntax error before: ") -> :incomplete
          true -> :complete
        end

      {:error, _} ->
        :complete
    end
  end

  defp show_value({:module, mod, _, _}), do: "=> #{inspect(mod)}\n"

  defp show_value(value), do: "=> #{inspect(value, limit: 50)}\n"

  defp show_error(e) do
    "** (" <> error_class(e) <> ") " <> Exception.message(e) <> "\n"
  end

  defp error_class(e), do: e.__struct__ |> Module.split() |> List.last() |> to_string()

  # ---- welcome ----

  defp banner do
    """
    Welcome to the home_elixir dev shell (IEx-style).
    Helpers: h(Name), ls(), pwd(), whereis(name).
    Variable bindings persist between lines. `reset()` clears them.
    """
  end
end
