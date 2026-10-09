defmodule HomeElixir.Shell do
  @moduledoc """
  A line-based Elixir eval shell over the live VM, for debugging.

  Each `eval/1` runs the line with `Code.eval_string/2`, captures any IO it
  produces, persists variable bindings across lines, and returns the combined
  terminal text. Because it runs in the running app's VM, it can reach the
  flows, the `Registry`, and the HA client.
  """

  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def eval(input) when is_binary(input), do: GenServer.call(__MODULE__, {:eval, input})
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({:eval, input}, _from, binding) do
    {text, new_binding} = do_eval(input, binding)
    {:reply, text, new_binding}
  end

  def handle_call(:reset, _from, _binding) do
    {:reply, welcome(), []}
  end

  # ---- internals ----

  # Value-only by design: capturing IO with ExUnit.CaptureIO corrupts the VM's
  # compiler state after a compile error, poisoning later evals. Returning the
  # last expression's value (use `inspect/1` to view anything) avoids that.
  defp do_eval(input, binding) do
    input = String.trim(input)

    if input == "" do
      {"", binding}
    else
      try do
        {value, new_binding} = Code.eval_string(input, binding)
        {value_str(value), new_binding}
      rescue
        e -> {Exception.format(:error, e, __STACKTRACE__), binding}
      end
    end
  end

  defp value_str(nil), do: ""
  defp value_str(value), do: "= #{inspect(value)}\n"

  defp welcome do
    """
    home_elixir debug shell — connected to the live VM
    try:
      HomeElixir.FlowStore.list()
      HomeElixir.Registry.loaded?(HomeElixir.Flows.WatchAll)
      HomeElixir.HA.connected?()
    variables persist across lines; type "reset" to clear
    """
  end
end
