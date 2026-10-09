defmodule HomeElixir.Web do
  @moduledoc """
  Web UI + JSON API for managing flows: a list page, an inline-highlighted
  editor for flow files, and a live-updating log page.

  The dev shell is the real IEx, launched from a terminal with `iex -S mix`
  (starts the app, then drops into IEx connected to the running node).

  Routes:
    GET  /                        flow list (load/unload/edit)
    GET  /edit                    editor for a new flow
    GET  /edit/:name              editor preloaded with flows/:name.ex
    GET  /logs                    live log view
    GET  /terminal                real IEx in the browser (xterm.js over WebSocket)
    GET  /api/flows               list flows (JSON)
    GET  /api/logs?since=N        log lines newer than N (JSON)
    POST /api/flows/:name/load | unload
    POST /api/flows/save | check
  """

  @behaviour Plug

  import Plug.Conn

  @hljs "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0"

  def init(_opts), do: []

  # ---- GET ----

  def call(%{method: "GET", request_path: "/"} = conn, _opts),
    do: html(conn, list_page())

  def call(%{method: "GET", request_path: "/api/flows"} = conn, _opts),
    do: json(conn, HomeElixir.FlowStore.list())

  def call(%{method: "GET", request_path: "/edit"} = conn, _opts),
    do: html(conn, editor_page(nil, new_flow_template()))

  def call(%{method: "GET", request_path: "/edit/" <> name} = conn, _opts),
    do: html(conn, editor_page(name, read_flow(name)))

  def call(%{method: "GET", request_path: "/logs"} = conn, _opts),
    do: html(conn, logs_page())

  def call(%{method: "GET", request_path: "/api/logs"} = conn, _opts),
    do: logs_endpoint(conn)

  def call(%{method: "GET", request_path: "/terminal"} = conn, _opts) do
    if websocket?(conn), do: upgrade_to_terminal(conn), else: html(conn, terminal_page())
  end

  # ---- POST ----

  def call(%{method: "POST"} = conn, _opts) do
    case conn.request_path |> String.split("/") do
      ["", "api", "flows", name, "load"] ->
        reply(conn, HomeElixir.FlowStore.load(name))

      ["", "api", "flows", name, "unload"] ->
        reply(conn, HomeElixir.FlowStore.unload(name))

      ["", "api", "flows", "save"] ->
        save_endpoint(conn)

      ["", "api", "flows", "check"] ->
        check_endpoint(conn)

      _ ->
        not_found(conn)
    end
  end

  def call(conn, _opts), do: not_found(conn)

  # ---- handlers ----

  defp save_endpoint(conn) do
    source = body(conn)

    case name_from_source(source) do
      nil ->
        text(conn, 400, "could not find a `defmodule` in the source")

      name ->
        try do
          save_flow(name, source)
          text(conn, 200, "saved " <> name <> ".ex")
        rescue
          e ->
            text(conn, 400, "saved " <> name <> ".ex, but reload failed:\n" <> Exception.message(e))
        end
    end
  end

  # Derive the flow file name from the module name in the source (single source
  # of truth, so the name and module can't drift apart).
  defp name_from_source(source) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source) do
      [_, mod] -> mod |> String.split(".") |> List.last() |> Macro.underscore()
      _ -> nil
    end
  end

  defp check_endpoint(conn) do
    case HomeElixir.FlowStore.check(body(conn)) do
      {:ok, msg} -> text(conn, 200, msg)
      {:error, msg} -> text(conn, 400, msg)
    end
  end

  defp logs_endpoint(conn) do
    lines = HomeElixir.Log.lines(parse_since(conn.query_string))
    json(conn, Enum.map(lines, fn {id, line} -> %{"id" => id, "line" => line} end))
  end

  defp parse_since(query) do
    case URI.decode_query(query || "") |> Map.get("since") do
      nil -> 0
      s ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> 0
        end
    end
  end

  # ---- flow file ops ----

  defp save_flow(name, source) do
    was_loaded = HomeElixir.FlowStore.loaded?(name)
    File.write!(flow_path(name), source)
    HomeElixir.FlowStore.forget(name)

    if was_loaded do
      HomeElixir.FlowStore.unload(name)
      HomeElixir.FlowStore.load(name)
    end

    :ok
  end

  defp read_flow(name) do
    case File.read(flow_path(name)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp flow_path(name) do
    dir = Application.get_env(:home_elixir, :flows_dir, "flows")
    Path.join(dir, "#{name}.ex")
  end

  defp new_flow_template do
    """
    defmodule HomeElixir.Flows.MyFlow do
      use HomeElixir.Flow

      # node("in", HomeElixir.Nodes.StateChanged, entity_id: "sensor.x")
      # node("out", HomeElixir.Nodes.Logger)
      # wire("in", "out")
    end
    """
  end

  # ---- conn helpers ----

  defp body(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp html(conn, body), do: conn |> put_resp_content_type("text/html") |> send_resp(200, body)
  defp json(conn, data), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(data))
  defp text(conn, status, data), do: conn |> put_resp_content_type("text/plain") |> send_resp(status, data)
  defp websocket?(conn) do
    case :lists.keyfind("upgrade", 1, conn.req_headers) do
      {"upgrade", value} -> String.downcase(value) == "websocket"
      _ -> false
    end
  end

  defp upgrade_to_terminal(conn) do
    cmd = conn.query_string |> URI.decode_query() |> Map.get("cmd", "iex -S mix")
    Plug.Conn.upgrade_adapter(conn, :websocket, {HomeElixir.Terminal, %{cmd: cmd}, %{}})
  end

  defp terminal_page do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Home Elixir IEx</title>
      <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
      <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
      <style>
        html, body { margin: 0; height: 100%; background: #1e1e1e; }
        #terminal { width: 100%; height: 100%; padding: 4px 8px; }
      </style>
    </head>
    <body>
      <div id="terminal"></div>
      <script>
        const term = new Terminal({ cursorBlink: true, fontFamily: "monospace", fontSize: 13 });
        const fit = new FitAddon.FitAddon();
        term.loadAddon(fit);
        term.open(document.getElementById("terminal"));
        fit.fit();
        const proto = location.protocol === "https:" ? "wss://" : "ws://";
        const ws = new WebSocket(proto + location.host + "/terminal");
        ws.binaryType = "arraybuffer";
        ws.onmessage = (e) => term.write(e.data instanceof ArrayBuffer ? new Uint8Array(e.data) : e.data);
        ws.onclose = () => term.write("\\r\\n\\x1b[90m[connection closed]\\x1b[0m\\r\\n");
        term.onData((d) => { if (ws.readyState === WebSocket.OPEN) ws.send(d); });
        window.addEventListener("resize", () => fit.fit());
        term.focus();
      </script>
    </body>
    </html>
    """
  end

  defp not_found(conn) do
    conn |> put_resp_content_type("application/json") |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:error, reason}), do: conn |> put_status(400) |> json(%{error: reason})
  defp reply(conn, other), do: json(conn, other)

  # ---- pages ----

  defp list_page do
    """
    #{base_html("Flows")}
      <table id="flows"></table>
      <p><a href="/terminal">IEx</a> &nbsp;·&nbsp; <a href="/logs">Logs</a> &nbsp;·&nbsp; <a href="/edit">New flow</a></p>
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
              `<td><button data-a="${action}">${btnLabel}</button> ` +
              `<a href="/edit/${f.name}">Edit</a></td>`;
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
    """
  end

  defp editor_page(_name, source) do
    source_json = Jason.encode!(source)

    """
    #{base_html("Edit flow")}
      <p><span id="hint"></span>
         <button id="check">Check</button>
         <button id="save">Save</button>
         <span id="status"></span></p>
      <div class="cm">
        <pre class="cm-hl" aria-hidden="true"><code id="hl" class="hljs language-elixir"></code></pre>
        <textarea id="editor" spellcheck="false" autocomplete="off"></textarea>
      </div>
      <script src="#{@hljs}/highlight.min.js"></script>
      <script src="#{@hljs}/languages/elixir.min.js"></script>
      <script>
        const FLOW = #{source_json};
        const editor = document.getElementById("editor");
        const hl = document.getElementById("hl");
        const pre = document.querySelector(".cm pre");
        const hint = document.getElementById("hint");
        const status = document.getElementById("status");
        editor.value = FLOW;
        function snake(n) {
          return n.replace(/([a-z0-9])([A-Z])/g, "$1_$2")
                  .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").toLowerCase();
        }
        function render() {
          hl.textContent = editor.value;
          hljs.highlightElement(hl);
          pre.scrollTop = editor.scrollTop;
          pre.scrollLeft = editor.scrollLeft;
          const m = editor.value.match(/defmodule\\s+([A-Za-z0-9_.]+)/);
          hint.textContent = m ? ("saves as " + snake(m[1].split(".").pop()) + ".ex") : "add a defmodule to save";
        }
        editor.addEventListener("input", render);
        editor.addEventListener("scroll", () => {
          pre.scrollTop = editor.scrollTop;
          pre.scrollLeft = editor.scrollLeft;
        });
        render();
        async function doSave() {
          status.textContent = "saving…";
          const r = await fetch("/api/flows/save", { method: "POST", body: editor.value });
          status.textContent = await r.text();
        }
        async function doCheck() {
          status.textContent = "checking…";
          const r = await fetch("/api/flows/check", { method: "POST", body: editor.value });
          status.textContent = await r.text();
        }
        document.getElementById("save").onclick = doSave;
        document.getElementById("check").onclick = doCheck;
      </script>
    """
  end

  defp logs_page do
    """
    #{base_html("Logs", dark: true)}
      <p><a href="/">&larr; Flows</a></p>
      <div id="logs"></div>
      <script>
        const box = document.getElementById("logs");
        let since = 0;
        async function poll() {
          try {
            const items = await (await fetch("/api/logs?since=" + since)).json();
            for (const it of items) {
              const div = document.createElement("div");
              div.textContent = it.line;
              if (it.line.startsWith("error")) div.className = "err";
              else if (it.line.startsWith("warning")) div.className = "warn";
              box.appendChild(div);
              since = it.id;
            }
            while (box.children.length > 800) box.removeChild(box.firstChild);
            box.scrollTop = box.scrollHeight;
          } catch (e) {}
        }
        poll();
        setInterval(poll, 1500);
      </script>
    """
  end

  defp base_html(title) do
    base_html(title, dark: false)
  end

  defp base_html(title, dark: true) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>#{title} — home_elixir</title>
      <link rel="stylesheet" href="#{@hljs}/styles/github-dark.min.css">
      <style>
        body { font-family: ui-monospace, monospace; margin: 1.5rem;
               background: #111; color: #ddd; }
        a { color: #6cf; }
        #out, .prompt { font: 13px/1.5 ui-monospace, monospace; }
        #out { white-space: pre-wrap; height: 70vh; overflow: auto;
               background: #0b0b0b; border: 1px solid #333; padding: .6rem; }
        .prompt { margin-top: .5rem; }
        .prompt input { width: 80%; background: #0b0b0b; color: #ddd;
                        border: 1px solid #333; padding: .3rem; }
        #logs { font: 13px/1.5 ui-monospace, monospace; white-space: pre-wrap;
                height: 75vh; overflow: auto; background: #0b0b0b;
                border: 1px solid #333; padding: .6rem; }
        #logs .err { color: #f66; }
        #logs .warn { color: #fc6; }
      </style>
    </head>
    <body>
    """
  end

  defp base_html(title, _dark) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>#{title} — home_elixir</title>
      <link rel="stylesheet" href="#{@hljs}/styles/github.min.css">
      <style>
        body { font-family: ui-monospace, monospace; margin: 1.5rem; color: #222; }
        a { color: #06c; }
        table { border-collapse: collapse; margin-top: 1rem; }
        th, td { border: 1px solid #ccc; padding: .4rem .9rem; text-align: left; }
        .loaded { color: #0a7a2f; font-weight: bold; }
        .off { color: #888; }
        button { cursor: pointer; }
        .cm { position: relative; border: 1px solid #ccc; height: 42vh;
              min-height: 280px; background: #f6f8fa; }
        .cm pre, .cm textarea { margin: 0; padding: 12px; position: absolute; inset: 0;
              width: 100%; height: 100%; box-sizing: border-box;
              font: 13px/1.5 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
              white-space: pre; overflow: auto; tab-size: 2; letter-spacing: 0; }
        .cm pre { pointer-events: none; z-index: 1; }
        .cm pre .hljs { display: block; padding: 0; margin: 0; background: transparent;
              overflow: visible; font: inherit; }
        .cm textarea { z-index: 2; background: transparent; color: transparent;
              caret-color: #222; border: 0; resize: none; outline: none; }
        #status { margin-left: .8rem; color: #0a7a2f; }
      </style>
    </head>
    <body>
    """
  end
end
