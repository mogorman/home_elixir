defmodule HomeElixir.Web do
  @moduledoc """
  A small web UI + JSON API for managing flows.

  * `GET  /` — the flow manager page
  * `GET  /api/flows` — list flows with load state
  * `POST /api/flows/:name/load`
  * `POST /api/flows/:name/unload`
  """

  @behaviour Plug

  import Plug.Conn

  def init(_opts), do: []

  def call(%{method: "GET", request_path: "/"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page())
  end

  def call(%{method: "GET", request_path: "/api/flows"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(HomeElixir.FlowStore.list()))
  end

  def call(%{method: "POST"} = conn, _opts) do
    case conn.request_path |> String.split("/") do
      ["", "api", "flows", name, "load"] ->
        conn |> reply(HomeElixir.FlowStore.load(name))

      ["", "api", "flows", name, "unload"] ->
        conn |> reply(HomeElixir.FlowStore.unload(name))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not found"}))
    end
  end

  def call(conn, _opts) do
    conn |> put_resp_content_type("application/json") |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end

  # ---- internals ----

  defp reply(conn, :ok) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  defp reply(conn, {:error, reason}) do
    conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: reason}))
  end

  defp reply(conn, other) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(other))
  end

  defp page do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>home_elixir — flows</title>
      <style>
        body { font-family: ui-monospace, monospace; margin: 2rem; color: #222; }
        table { border-collapse: collapse; margin-top: 1rem; }
        th, td { border: 1px solid #ccc; padding: .4rem .9rem; text-align: left; }
        .loaded { color: #0a7a2f; font-weight: bold; }
        .off { color: #888; }
        button { cursor: pointer; }
      </style>
    </head>
    <body>
      <h1>Flows</h1>
      <table id="flows"></table>
      <script>
        async function refresh() {
          const flows = await (await fetch("/api/flows")).json();
          const table = document.getElementById("flows");
          table.innerHTML = "<tr><th>name</th><th>module</th><th>status</th><th></th></tr>";
          for (const f of flows) {
            const tr = document.createElement("tr");
            const cls = f.loaded ? "loaded" : "off";
            const label = f.loaded ? "loaded" : "not loaded";
            const action = f.loaded ? "unload" : "load";
            const btnLabel = f.loaded ? "Unload" : "Load";
            tr.innerHTML =
              `<td>${f.name}</td><td>${f.module}</td>` +
              `<td class="${cls}">${label}</td>` +
              `<td><button>${btnLabel}</button></td>`;
            tr.querySelector("button").onclick = async () => {
              await fetch(`/api/flows/${f.name}/${action}`, { method: "POST" });
              refresh();
            };
            table.appendChild(tr);
          }
        }
        refresh();
        setInterval(refresh, 3000);
      </script>
    </body>
    </html>
    """
  end
end
