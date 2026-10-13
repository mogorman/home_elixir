defmodule HomeElixir.Web do
  @moduledoc """
  Web UI + JSON API for managing flows: a list page, an inline-highlighted
  editor for flow files, and a live-updating log page.

  The `/terminal` route gives the browser a real IEx attached to the running
  app: when the app is a named node it opens `iex --remsh home_elixir` (a
  distributed connection into this VM), otherwise it falls back to `iex -S mix`.

  Routes:
    GET  /                        flow list (load/unload/edit)
    GET  /edit                    editor for a new flow
    GET  /edit/:name              editor preloaded with flows/:name.ex
    GET  /logs                    live log view
    GET  /terminal                real IEx in the browser (xterm.js over WebSocket)
    GET  /api/flows               list flows (JSON)
    GET  /api/entity_tree         HA Area > Device > Entity tree (JSON)
    GET  /api/logs?since=N        log lines newer than N (JSON)
    GET  /api/flows/:name/ui      UI elements for one flow (JSON)
    POST /api/flows/:name/load | unload | reload
    POST /api/flows/reload        reload all loaded flows
    POST /api/flows/save | check
  """

  @behaviour Plug

  import Plug.Conn

  @hljs "/static/hljs"
  @bootstrap "/static/bootstrap/bootstrap.min.css"

  def init(_opts), do: []

  # ---- GET ----

  def call(%{method: "GET", request_path: "/"} = conn, _opts),
    do: html(conn, list_page())

  def call(%{method: "GET", request_path: "/api/flows"} = conn, _opts),
    do: json(conn, HomeElixir.FlowStore.list())

  def call(%{method: "GET", request_path: "/api/entity_tree"} = conn, _opts),
    do: json(conn, HomeElixir.EntityBrowser.tree())

  def call(%{method: "GET", request_path: "/controls"} = conn, _opts),
    do: html(conn, controls_page())

  def call(%{method: "GET", request_path: "/api/ui"} = conn, _opts),
    do: json(conn, HomeElixir.FlowStore.ui())

  # Live UI updates over a web socket (pushes state-badge changes to the browser).
  def call(%{method: "GET", request_path: "/api/ui/ws"} = conn, _opts) do
    if websocket?(conn), do: upgrade_to_ui_ws(conn), else: text(conn, 400, "web socket only")
  end

  def call(%{method: "GET", request_path: "/api/flows/" <> rest} = conn, _opts) do
    case String.split(rest, "/") do
      [name, "ui"] -> json(conn, HomeElixir.FlowStore.flow_ui(name))
      _ -> not_found(conn)
    end
  end

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

  def call(%{method: "GET", request_path: "/static/" <> rest} = conn, _opts),
    do: static_file(conn, rest)

  # ---- POST ----

  def call(%{method: "POST"} = conn, _opts) do
    case conn.request_path |> String.split("/") do
      ["", "api", "flows", name, "load"] ->
        reply(conn, HomeElixir.FlowStore.load(name))

      ["", "api", "flows", name, "unload"] ->
        reply(conn, HomeElixir.FlowStore.unload(name))

      ["", "api", "flows", name, "reload"] ->
        reply(conn, HomeElixir.FlowStore.reload(name))

      ["", "api", "flows", "save"] ->
        save_endpoint(conn)

      ["", "api", "flows", "check"] ->
        check_endpoint(conn)

      ["", "api", "flows", "reload"] ->
        reply(conn, HomeElixir.FlowStore.reload_all())

      ["", "api", "ui", "click"] ->
        click_endpoint(conn)

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
          text(conn, 200, "saved " <> name <> ".ex (reload to apply)")
        rescue
          e ->
            text(conn, 400, "saved " <> name <> ".ex, but save failed:\n" <> Exception.message(e))
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

  defp click_endpoint(conn) do
    case Jason.decode(body(conn)) do
      {:ok, %{"name" => name, "node" => node} = data} ->
        reply(conn, HomeElixir.FlowStore.click(name, node, Map.get(data, "payload")))

      {:ok, _} ->
        conn |> put_status(400) |> json(%{error: "name and node required"})

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid json body"})
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
    File.write!(flow_path(name), source)
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

  defp html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> send_resp(200, body)
  end
  defp json(conn, data), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(data))
  defp text(conn, status, data), do: conn |> put_resp_content_type("text/plain") |> send_resp(status, data)

  # Serves bundled assets under priv/static (currently the highlight.js build).
  defp static_file(conn, name) do
    root = Application.app_dir(:home_elixir, "priv/static") |> Path.expand()
    path = Path.join(root, name) |> Path.expand()

    cond do
      not String.starts_with?(path, root <> "/") ->
        not_found(conn)

      File.regular?(path) ->
        type =
          case Path.extname(path) do
            ".js" -> "text/javascript"
            ".css" -> "text/css"
            _ -> "application/octet-stream"
          end

        conn
        |> put_resp_content_type(type)
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, File.read!(path))

      true ->
        not_found(conn)
    end
  end
  defp websocket?(conn) do
    case :lists.keyfind("upgrade", 1, conn.req_headers) do
      {"upgrade", value} -> String.downcase(value) == "websocket"
      _ -> false
    end
  end

  defp upgrade_to_terminal(conn) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {HomeElixir.Terminal, %{}, %{}})
  end

  defp upgrade_to_ui_ws(conn) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {HomeElixir.WebUI, %{}, %{}})
  end

  defp terminal_page do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Home Elixir IEx</title>
      <link href="#{@bootstrap}" rel="stylesheet">
      <link rel="stylesheet" href="/static/xterm/xterm.min.css">
      <script src="/static/xterm/xterm.min.js"></script>
      <script src="/static/xterm/addon-fit.min.js"></script>
      #{theme_script()}
      <style>
        html, body { height: 100%; margin: 0; }
        body { display: flex; flex-direction: column; }
        #terminal { flex: 1; padding: 4px 8px; box-sizing: border-box; background: #1e1e1e; }
      </style>
    </head>
    <body>
    #{navbar_html(:iex)}
      <div id="terminal"></div>
      <script>
        const term = new Terminal({ cursorBlink: true, fontFamily: "monospace", fontSize: 13, convertEol: true });
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
        window.addEventListener("beforeunload", () => { try { ws.close(); } catch (_) {} });
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
      <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center">
          <span class="fw-semibold">Flows</span>
          <div class="d-flex gap-1">
            <a href="/edit" class="btn btn-sm btn-primary">New flow</a>
            <button id="reload-all" class="btn btn-sm btn-outline-secondary">Reload all</button>
          </div>
        </div>
        <table class="table table-hover align-middle mb-0">
          <thead><tr><th>name</th><th>module</th><th>status</th><th class="text-end">actions</th></tr></thead>
          <tbody id="flows"></tbody>
        </table>
      </div>
      <script>
        async function act(name, action) {
          await fetch(`/api/flows/${name}/${action}`, { method: "POST" });
          refresh();
        }
        async function reloadAll() {
          await fetch("/api/flows/reload", { method: "POST" });
          refresh();
        }
        function addBtn(parent, label, cls, fn) {
          const b = document.createElement("button");
          b.className = "btn btn-sm " + cls;
          b.textContent = label;
          b.onclick = fn;
          parent.appendChild(b);
        }
        async function refresh() {
          const flows = await (await fetch("/api/flows")).json();
          const tbody = document.getElementById("flows");
          tbody.innerHTML = "";
          for (const f of flows) {
            const tr = document.createElement("tr");
            const actions = document.createElement("div");
            actions.className = "d-flex gap-1 justify-content-end";
            if (f.loaded) {
              addBtn(actions, "Reload", "btn-outline-secondary", () => act(f.name, "reload"));
              addBtn(actions, "Unload", "btn-outline-secondary", () => act(f.name, "unload"));
            } else {
              addBtn(actions, "Load", "btn-primary", () => act(f.name, "load"));
            }
            const edit = document.createElement("a");
            edit.className = "btn btn-sm btn-outline-secondary";
            edit.href = "/edit/" + f.name;
            edit.textContent = "Edit";
            actions.appendChild(edit);
            tr.innerHTML =
              `<td class="fw-semibold">${f.name}</td>` +
              `<td class="text-secondary">${f.module}</td>` +
              `<td><span class="badge ${f.loaded ? "bg-success" : "bg-secondary"}">${f.loaded ? "loaded" : "not loaded"}</span></td>`;
            tr.appendChild(actions);
            tbody.appendChild(tr);
          }
        }
        document.getElementById("reload-all").onclick = reloadAll;
        refresh();
        setInterval(refresh, 3000);
      </script>
    """
  end

  defp controls_page do
    """
    #{base_html("Controls", :controls)}
      <div id="controls" class="d-flex flex-column gap-3"></div>
      <script>
        #{control_js()}
        async function refresh() {
          const els = await (await fetch("/api/ui")).json();
          const box = document.getElementById("controls");
          box.innerHTML = "";
          if (!els.length) {
            box.innerHTML = '<div class="alert alert-info mb-0">No controls yet. Add a node with a <code>ui:</code> config (e.g. an Inject with a button) and load its flow.</div>';
            return;
          }
          const groups = new Map();
          for (const e of els) {
            if (!groups.has(e.name)) groups.set(e.name, []);
            groups.get(e.name).push(e);
          }
          for (const [flow, items] of groups) {
            const card = document.createElement("div");
            card.className = "card";
            const head = document.createElement("div");
            head.className = "card-header fw-semibold";
            head.textContent = flow;
            const body = document.createElement("div");
            body.className = "card-body d-flex flex-wrap gap-2";
            for (const e of items) body.appendChild(renderControl(e, "btn-primary"));
            card.appendChild(head);
            card.appendChild(body);
            box.appendChild(card);
          }
        }
        refresh();
        // Push-based: refresh on (re)connect to resync, then update badges live.
        connectUI({ state: updateBadge }, refresh);
      </script>
    """
  end

  defp editor_page(name, source) do
    source_json = Jason.encode!(source)
    name_json = Jason.encode!(name)

    """
    #{base_html("Edit flow", :edit)}
      <style>
        .cm { position: relative; border: 1px solid var(--bs-border-color); height: 46vh;
              min-height: 280px; background: var(--bs-tertiary-bg); }
        .cm pre, .cm textarea { margin: 0; padding: 12px; position: absolute; inset: 0;
              width: 100%; height: 100%; box-sizing: border-box;
              font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
              font-size: 13px; line-height: 20px;
              white-space: pre; overflow: auto; tab-size: 2; letter-spacing: 0;
              text-size-adjust: 100%; -webkit-text-size-adjust: 100%; }
        @media (max-width: 768px) {
          .cm pre, .cm textarea { font-size: 16px; line-height: 24px; }
        }
        .cm pre { pointer-events: none; z-index: 1; }
        .cm pre .hljs { display: block; padding: 0; margin: 0; background: transparent;
              overflow: visible; font: inherit; }
        .cm textarea { z-index: 2; background: transparent; color: transparent;
              caret-color: var(--bs-body-color); border: 0; resize: none; outline: none; }
        .flowlogs { font-family: ui-monospace, monospace; font-size: 13px; line-height: 1.5;
              white-space: pre-wrap; height: 240px; overflow: auto; }
        .ent-row { cursor: pointer; border-bottom: 1px solid var(--bs-border-color); }
        .ent-row:hover { background: var(--bs-tertiary-bg); }
        #entities-card summary { cursor: pointer; }
        #ent-overlay { position: fixed; inset: 0; z-index: 1070; display: flex;
               align-items: center; justify-content: center; background: rgba(0, 0, 0, .45); }
        #entities-card { width: min(940px, 94vw); height: min(72vh, 680px);
               display: flex; flex-direction: column; overflow: hidden; }
        #entities-card .card-header { flex: 0 0 auto; }
        #entities-card .card-body { flex: 1 1 auto; overflow: auto; }
      </style>
      <div class="card">
        <div class="card-body">
          <div class="d-flex align-items-center gap-2 flex-wrap mb-2">
            <span id="hint" class="text-secondary small"></span>
            <label class="ms-2 small">Name
              <input id="name" class="form-control form-control-sm d-inline-block" style="width: 11rem" spellcheck="false">
            </label>
            <button id="check" class="btn btn-sm btn-outline-secondary">Check</button>
            <button id="reload" class="btn btn-sm btn-outline-secondary">Reload</button>
            <button id="entities-btn" class="btn btn-sm btn-outline-secondary">Entities</button>
            <button id="save" class="btn btn-sm btn-primary">Save</button>
            <span id="status" class="text-success small"></span>
          </div>
          <div class="cm">
            <pre class="cm-hl" aria-hidden="true"><code id="hl" class="hljs language-elixir"></code></pre>
            <textarea id="editor" wrap="off" spellcheck="false" autocomplete="off"></textarea>
          </div>
        </div>
      </div>
      <div id="ent-overlay" class="d-none">
        <div id="entities-card" class="card">
          <div class="card-header d-flex align-items-center gap-2 flex-wrap">
            <span class="fw-semibold">Entities</span>
            <input id="ent-search" class="form-control form-control-sm" style="max-width: 22rem"
                   placeholder="Search name or entity_id…" spellcheck="false">
            <button id="ent-refresh" class="btn btn-sm btn-outline-secondary">Refresh</button>
            <span id="ent-status" class="text-secondary small"></span>
            <button id="ent-close" class="btn btn-sm btn-outline-secondary ms-auto" aria-label="Close">×</button>
          </div>
          <div class="card-body p-0">
            <div id="ent-tree"></div>
          </div>
        </div>
      </div>
      <div id="panels" class="row g-3 d-none">
        <div class="col-12 col-lg-6">
          <div class="card h-100">
            <div class="card-header fw-semibold">Controls</div>
            <div class="card-body"><div id="ctrl" class="d-flex flex-wrap gap-2"></div></div>
          </div>
        </div>
        <div class="col-12 col-lg-6">
          <div class="card h-100">
            <div class="card-header fw-semibold">Flow logs</div>
            <div class="card-body p-0"><div id="flowlogs" class="flowlogs"></div></div>
          </div>
        </div>
      </div>
      <link id="hljs-theme" href="#{@hljs}/styles/github-dark.min.css" rel="stylesheet">
      <script src="#{@hljs}/highlight.min.js"></script>
      <script src="#{@hljs}/languages/elixir.min.js"></script>
      <script>
        #{control_js()}
        const FLOW = #{source_json};
        const FLOWNAME = #{name_json};
        const editor = document.getElementById("editor");
        const hl = document.getElementById("hl");
        const pre = document.querySelector(".cm pre");
        const hint = document.getElementById("hint");
        const status = document.getElementById("status");
        const nameInput = document.getElementById("name");
        editor.value = FLOW;
        let savedSource = FLOW;
        function snake(n) {
          return n.replace(/([a-z0-9])([A-Z])/g, "$1_$2")
                  .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").toLowerCase();
        }
        function moduleSegment(name) {
          const seg = name.replace(/[^A-Za-z0-9]+/g, "_").split("_").filter(Boolean)
            .map((s) => s[0].toUpperCase() + s.slice(1).toLowerCase()).join("");
          return seg || "MyFlow";
        }
        function currentModule() {
          const m = editor.value.match(/defmodule\\s+([A-Za-z0-9_.]+)/);
          return m ? m[1] : null;
        }
        function setCurrentModule(mod) {
          const m = editor.value.match(/defmodule\\s+[A-Za-z0-9_.]+/);
          if (!m) return;
          editor.value = editor.value.slice(0, m.index) + "defmodule " + mod +
                         editor.value.slice(m.index + m[0].length);
        }
        function render() {
          let html;
          const escaped = editor.value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
          if (typeof hljs === "undefined") {
            html = escaped;
          } else {
            try {
              html = hljs.highlight(editor.value, { language: "elixir" }).value;
            } catch (e) {
              html = escaped;
            }
          }
          if (editor.value.endsWith("\\n")) html += " ";
          hl.innerHTML = html;
          pre.scrollTop = editor.scrollTop;
          pre.scrollLeft = editor.scrollLeft;
          const mod = currentModule();
          hint.textContent = mod ? ("saves as " + snake(mod.split(".").pop()) + ".ex")
                                 : "add a defmodule to save";
          if (mod && document.activeElement !== nameInput) {
            const n = snake(mod.split(".").pop());
            if (nameInput.value !== n) nameInput.value = n;
          }
        }
        nameInput.addEventListener("input", () => {
          setCurrentModule("HomeElixir.Flows." + moduleSegment(nameInput.value));
          render();
        });
        editor.addEventListener("input", render);
        window.addEventListener("beforeunload", (e) => {
          if (editor.value !== savedSource) { e.preventDefault(); e.returnValue = ""; }
        });
        editor.addEventListener("scroll", () => {
          pre.scrollTop = editor.scrollTop;
          pre.scrollLeft = editor.scrollLeft;
        });
        render();
        async function doSave() {
          status.textContent = "saving…";
          const r = await fetch("/api/flows/save", { method: "POST", body: editor.value });
          status.textContent = await r.text();
          if (r.ok) savedSource = editor.value;
        }
        async function doCheck() {
          status.textContent = "checking…";
          const r = await fetch("/api/flows/check", { method: "POST", body: editor.value });
          status.textContent = await r.text();
        }
        async function doReload() {
          if (!FLOWNAME) { status.textContent = "save first"; return; }
          status.textContent = "reloading…";
          const r = await fetch(`/api/flows/${FLOWNAME}/reload`, { method: "POST" });
          const t = await r.text();
          status.textContent = r.ok ? "reloaded" : t;
          refreshControls();
        }
        document.getElementById("save").onclick = doSave;
        document.getElementById("check").onclick = doCheck;
        document.getElementById("reload").onclick = doReload;
        async function refreshControls() {
          if (!FLOWNAME) return;
          const els = await (await fetch(`/api/flows/${FLOWNAME}/ui`)).json();
          const box = document.getElementById("ctrl");
          box.innerHTML = "";
          if (!els.length) { box.innerHTML = '<span class="text-secondary small">no ui elements</span>'; return; }
          for (const e of els) box.appendChild(renderControl(e, "btn-sm btn-primary"));
        }
        const flowlogBox = document.getElementById("flowlogs");
        let flowLastId = 0, flowSyncing = false;
        function flowLogDiv(line) {
          const d = document.createElement("div");
          d.textContent = line;
          if (line.startsWith("error")) d.className = "text-danger";
          else if (line.startsWith("warning")) d.className = "text-warning-emphasis";
          return d;
        }
        function appendFlowLine(line) {
          flowlogBox.appendChild(flowLogDiv(line));
          while (flowlogBox.children.length > 300) flowlogBox.removeChild(flowlogBox.firstChild);
          flowlogBox.scrollTop = flowlogBox.scrollHeight;
        }
        function onFlowLog(msg) {
          if (flowSyncing) return;
          if (msg.id > flowLastId) {
            if (msg.line.includes("[" + FLOWNAME + "]")) appendFlowLine(msg.line);
            flowLastId = msg.id;
          }
        }
        async function resyncFlowLogs() {
          flowSyncing = true;
          try {
            const items = await (await fetch("/api/logs?since=" + flowLastId)).json();
            for (const it of items) {
              if (it.line.includes("[" + FLOWNAME + "]")) appendFlowLine(it.line);
              flowLastId = it.id;
            }
          } catch (e) {}
          flowSyncing = false;
        }
        if (FLOWNAME) {
          document.getElementById("panels").classList.remove("d-none");
          refreshControls();
          // Push-based: resync on (re)connect, then update badges + flow logs live.
          connectUI({ state: updateBadge, log: onFlowLog },
            () => { refreshControls(); resyncFlowLogs(); });
        }
        function setHljsTheme(t) {
          document.getElementById("hljs-theme").href = "#{@hljs}/styles/" + (t === "dark" ? "github-dark.min.css" : "github.min.css");
        }
        setHljsTheme(document.documentElement.getAttribute("data-bs-theme"));
        document.addEventListener("themechange", function (e) { setHljsTheme(e.detail); });
        // ---- entity browser: Area > Device > Entity tree, or flat when searching ----
        const entOverlay = document.getElementById("ent-overlay");
        const entTree = document.getElementById("ent-tree");
        const entSearch = document.getElementById("ent-search");
        const entStatus = document.getElementById("ent-status");
        let entData = null;
        function openEnt() {
          entOverlay.classList.remove("d-none");
          entSearch.focus();
          if (!entData) loadEntities();
        }
        function closeEnt() { entOverlay.classList.add("d-none"); }
        document.getElementById("entities-btn").onclick = () =>
          entOverlay.classList.contains("d-none") ? openEnt() : closeEnt();
        document.getElementById("ent-close").onclick = closeEnt;
        entOverlay.addEventListener("click", (e) => { if (e.target === entOverlay) closeEnt(); });
        document.addEventListener("keydown", (e) => {
          if (e.key === "Escape" && !entOverlay.classList.contains("d-none")) closeEnt();
        });
        document.getElementById("ent-refresh").onclick = () => loadEntities();
        entSearch.addEventListener("input", renderEnt);
        async function loadEntities() {
          entStatus.textContent = "loading…";
          try { entData = await (await fetch("/api/entity_tree")).json(); }
          catch (e) { entData = null; entStatus.textContent = "error"; renderEnt(); return; }
          entStatus.textContent = entData.connected ? "" : "HA not connected";
          renderEnt();
        }
        function entRow(e, crumb) {
          const d = document.createElement("div");
          d.className = "ent-row d-flex align-items-center gap-2 px-3 py-1";
          if (crumb) {
            const c = document.createElement("span");
            c.className = "text-secondary small";
            c.textContent = crumb;
            d.appendChild(c);
          }
          const code = document.createElement("code");
          code.textContent = e.id;
          if (e.cls) code.title = e.cls;
          const name = document.createElement("span");
          name.className = "text-secondary small";
          name.textContent = e.name;
          const st = document.createElement("span");
          st.className = "badge bg-secondary ms-auto";
          st.textContent = (e.state == null ? "-" : e.state) + (e.unit ? " " + e.unit : "");
          d.appendChild(code);
          d.appendChild(name);
          d.appendChild(st);
          d.onclick = () => insertEntity(e.id);
          return d;
        }
        function renderEnt() {
          entTree.innerHTML = "";
          if (!entData) return;
          if (!entData.connected) {
            entTree.innerHTML = '<div class="text-secondary small p-3">Home Assistant is not connected.</div>';
            return;
          }
          const q = entSearch.value.trim().toLowerCase();
          if (q) {
            const all = [];
            for (const a of entData.areas) {
              for (const dv of (a.devices || [])) for (const e of dv.entities) all.push([e, a.name + " / " + dv.name]);
              for (const e of (a.entities || [])) all.push([e, a.name]);
            }
            const matches = all.filter(([e]) => e.id.toLowerCase().includes(q) || (e.name || "").toLowerCase().includes(q));
            if (!matches.length) {
              entTree.innerHTML = '<div class="text-secondary small p-3">No matching entities.</div>';
              return;
            }
            for (const [e, crumb] of matches) entTree.appendChild(entRow(e, crumb));
            return;
          }
          for (const a of entData.areas) {
            const areaCount = (a.devices || []).reduce((n, dv) => n + dv.entities.length, 0) + (a.entities || []).length;
            const areaDet = document.createElement("details");
            const aSum = document.createElement("summary");
            aSum.className = "px-3 py-1 fw-semibold";
            aSum.textContent = a.name + " (" + areaCount + ")";
            areaDet.appendChild(aSum);
            const body = document.createElement("div");
            for (const dv of (a.devices || [])) {
              const dDet = document.createElement("details");
              const dSum = document.createElement("summary");
              dSum.className = "px-3 py-1 ms-3";
              dSum.textContent = dv.name + " (" + dv.entities.length + ")";
              dDet.appendChild(dSum);
              const dBod = document.createElement("div");
              for (const e of dv.entities) dBod.appendChild(entRow(e));
              dDet.appendChild(dBod);
              body.appendChild(dDet);
            }
            for (const e of (a.entities || [])) body.appendChild(entRow(e));
            areaDet.appendChild(body);
            entTree.appendChild(areaDet);
          }
        }
        function insertEntity(id) {
          const s = editor.selectionStart, e = editor.selectionEnd;
          editor.value = editor.value.slice(0, s) + id + editor.value.slice(e);
          editor.selectionStart = editor.selectionEnd = s + id.length;
          render();
          closeEnt();
        }
      </script>
    """
  end

  defp logs_page do
    """
    #{base_html("Logs", :logs)}
      <div id="logs" class="rounded border p-2"
           style="font-family: ui-monospace, monospace; font-size: 13px; line-height: 1.5;
                  white-space: pre-wrap; height: 78vh; overflow: auto;"></div>
      <script>
        #{control_js()}
        const box = document.getElementById("logs");
        let lastId = 0, syncing = false;
        function logDiv(line) {
          const d = document.createElement("div");
          d.textContent = line;
          if (line.startsWith("error")) d.className = "text-danger";
          else if (line.startsWith("warning")) d.className = "text-warning-emphasis";
          return d;
        }
        function appendLine(line) {
          box.appendChild(logDiv(line));
          while (box.children.length > 800) box.removeChild(box.firstChild);
          box.scrollTop = box.scrollHeight;
        }
        function onLog(msg) {
          if (syncing) return;
          if (msg.id > lastId) { appendLine(msg.line); lastId = msg.id; }
        }
        async function resync() {
          syncing = true;
          try {
            const items = await (await fetch("/api/logs?since=" + lastId)).json();
            for (const it of items) { appendLine(it.line); lastId = it.id; }
          } catch (e) {}
          syncing = false;
        }
        connectUI({ log: onLog }, resync);
      </script>
    """
  end

  # Shared control renderer (state badge or clickable button) for the /controls
  # page and the editor's live-controls panel, plus the live-update web socket
  # helpers both pages use.
  defp control_js do
    """
    function renderControl(e, btnClass) {
      if (e.type === "state") {
        const b = document.createElement("span");
        const on = e.value === true || e.value === "on";
        const off = e.value === false || e.value === "off";
        b.className = "badge " + (on ? "bg-success" : off ? "bg-secondary" : "bg-info text-dark");
        b.textContent = (e.label || e.node) + ": " + (e.value === null || e.value === undefined ? "-" : e.value);
        b.dataset.flow = e.name;
        b.dataset.node = e.node;
        b.dataset.label = e.label || e.node;
        return b;
      }
      const b = document.createElement("button");
      b.className = "btn " + (btnClass || "btn-primary");
      b.textContent = e.label || e.node;
      b.onclick = async () => {
        await fetch("/api/ui/click", { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name: e.name, node: e.node, payload: e.payload }) });
      };
      return b;
    }
    // Reconnect-with-backoff web socket. `handlers` maps a push `type` to a fn(msg).
    function connectUI(handlers, onOpen, retryMs) {
      const proto = location.protocol === "https:" ? "wss://" : "ws://";
      const ws = new WebSocket(proto + location.host + "/api/ui/ws");
      if (onOpen) ws.onopen = () => onOpen();
      ws.onmessage = (e) => {
        try { const m = JSON.parse(e.data); if (handlers[m.type]) handlers[m.type](m); } catch (_) {}
      };
      ws.onclose = () => setTimeout(() => connectUI(handlers, onOpen, retryMs), retryMs || 2000);
      return ws;
    }
    // Update one badge from a pushed {flow, node, value} update.
    function updateBadge(u) {
      const el = document.querySelector('[data-flow="' + u.flow + '"][data-node="' + u.node + '"]');
      if (el) el.textContent = el.dataset.label + ": " + (u.value === null || u.value === undefined ? "-" : u.value);
    }
    """
  end

  defp base_html(title, active \\ :flows) do
    nav = navbar_html(active)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{title} — home_elixir</title>
      <link href="#{@bootstrap}" rel="stylesheet">
      #{theme_script()}
    </head>
    <body class="p-3">
    #{nav}
    """
  end

  # Sets the theme before first paint (no flash): a manual choice stored in
  # localStorage wins, otherwise the browser's light/dark preference, defaulting
  # to dark.
  defp theme_script do
    """
    <script>
      (function () {
        var t = localStorage.getItem("theme");
        if (!t) t = (window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches) ? "light" : "dark";
        document.documentElement.setAttribute("data-bs-theme", t);
      })();
    </script>
    """
  end

  # Shared top navbar (all pages) + the light/dark toggle. The toggle persists
  # to localStorage and fires a `themechange` event pages can listen to.
  defp navbar_html(active) do
    a = fn key -> if key == active, do: " active", else: "" end

    """
    <nav class="navbar navbar-expand-lg bg-body-tertiary rounded-3 mb-3 px-3">
      <div class="container-fluid">
        <a class="navbar-brand fw-semibold" href="/">home_elixir</a>
        <ul class="navbar-nav gap-1 flex-wrap">
          <li class="nav-item"><a class="nav-link#{a.(:flows)}" href="/">Flows</a></li>
          <li class="nav-item"><a class="nav-link#{a.(:controls)}" href="/controls">Controls</a></li>
          <li class="nav-item"><a class="nav-link#{a.(:logs)}" href="/logs">Logs</a></li>
          <li class="nav-item"><a class="nav-link#{a.(:iex)}" href="/terminal">IEx</a></li>
        </ul>
        <button id="theme-toggle" class="btn btn-outline-secondary btn-sm ms-2"></button>
      </div>
    </nav>
    <script>
      (function () {
        var btn = document.getElementById("theme-toggle");
        var mq = window.matchMedia ? matchMedia("(prefers-color-scheme: light)") : null;
        function theme() { return document.documentElement.getAttribute("data-bs-theme"); }
        function label() { btn.textContent = theme() === "dark" ? "Light" : "Dark"; }
        function apply(t) {
          document.documentElement.setAttribute("data-bs-theme", t);
          document.dispatchEvent(new CustomEvent("themechange", { detail: t }));
          label();
        }
        btn.addEventListener("click", function () {
          var next = theme() === "dark" ? "light" : "dark";
          localStorage.setItem("theme", next);
          apply(next);
        });
        if (mq && mq.addEventListener) mq.addEventListener("change", function (e) {
          if (!localStorage.getItem("theme")) apply(e.matches ? "light" : "dark");
        });
        label();
      })();
    </script>
    """
  end
end
