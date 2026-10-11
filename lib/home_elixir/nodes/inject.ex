defmodule HomeElixir.Nodes.Inject do
  @moduledoc """
  Passthrough source node: re-emits each incoming message unchanged. Use it as
  the entry point of a flow that starts from an external trigger (a web button
  via the `ui:` config) rather than from an HA event.

  Pair it with a `ui:` config so the web UI renders a control for it:

      node("start", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Go"})
      wire("start", "next")
  """
  @behaviour HomeElixir.Node

  @impl true
  def handle(msg, state), do: {[msg], state}
end
