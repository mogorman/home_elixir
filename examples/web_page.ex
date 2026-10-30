defmodule HomeElixir.Flows.Examples.WebPage do
  @moduledoc """
  Example: a flow that serves its own web page.

  `web_page("/web_page")` registers the URL; `page_html/0` is the EEx template
  (kept inline in this file — no separate template) and `page_data/0` hands it
  data. `GET /web_page` renders the page. It requires a login by default; pass
  `public: true` to `web_page/2` to allow anonymous access.

  The page shows a FlowState-backed count. Bump it with the **+1** / **Reset**
  buttons on the Controls page (also mirrored by the **Count** badge there);
  `page_data/0` runs scoped to this flow, so it reads the flow's own FlowState.
  **Copy this example to try it** — examples only run once copied into your
  flows. No Home Assistant needed.
  """
  use HomeElixir.Flow

  @behaviour HomeElixir.Node

  alias HomeElixir.FlowState

  # Registers this flow's web page at GET /web_page.
  web_page("/web_page")

  # Bindings for the page template. Runs scoped to this flow, so it can read
  # the flow's own FlowState.
  def page_data, do: %{count: FlowState.get(:count, 0)}

  # The page: an EEx template. Bindings are bare variables — `count`, plus the
  # reserved `user` / `name` / `base`.
  def page_html do
    """
    <!doctype html>
    <html>
      <head><meta charset="utf-8"><title>Web Page Example</title></head>
      <body>
        <h1>Web Page Example</h1>
        <p>This page is served by the flow itself. Current count: <strong><%= count %></strong>.</p>
        <p>Viewed by: <%= user && elem(user, 0) %> &middot; flow: <%= name %></p>
        <p>Change the count from the <a href="controls">Controls</a> page, then reload this page.</p>
      </body>
    </html>
    """
  end

  # Buttons change the count (persisted in FlowState, survives restarts).
  def handle(%{payload: "inc"}), do: FlowState.update(:count, &(&1 + 1), 0)
  def handle(%{payload: "reset"}), do: FlowState.put(:count, 0)

  # This flow doubles as its own Count badge on the Controls page.
  @impl true
  def init(_), do: %{state: FlowState.get(:count)}
  @impl true
  def handle(_msg, _data), do: {[nil], %{state: FlowState.get(:count)}}

  node("inc", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "+1", payload: "inc"})
  node("reset", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Reset", payload: "reset"})
  node("count", __MODULE__, ui: %{type: "state", label: "Count"})
end
