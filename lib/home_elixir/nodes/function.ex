defmodule HomeElixir.Nodes.Function do
  @moduledoc """
  Applies a function to each message. Config is `fun: &Mod.fun/1` (a remote
  function). It receives the `HomeElixir.Msg` and returns a new `Msg` (or a raw
  value, wrapped as `payload`), or `nil` to drop the message.
  """
  @behaviour HomeElixir.Node

  @impl true
  def init(config), do: Map.fetch!(config, :fun)

  @impl true
  def handle(msg, fun) do
    {[wrap(fun.(msg))], fun}
  end

  defp wrap(nil), do: nil
  defp wrap(%HomeElixir.Msg{} = m), do: m
  defp wrap(other), do: %HomeElixir.Msg{payload: other}
end
