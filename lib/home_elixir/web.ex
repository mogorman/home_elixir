defmodule HomeElixir.Web do
  @moduledoc """
  Web UI + JSON API for managing flows: a list page, a CodeMirror-free
  highlight.js editor for creating/editing flow files, and a line-based dev
  shell over the live VM.

  Routes:
    GET  /                        flow list (load/unload/edit)
    GET  /edit                    editor for a new flow
    GET  /edit/:name              editor preloaded with flows/:name.ex
    GET  /shell                   dev shell
    GET  /api/flows               list flows (JSON)
    POST /api/flows/:name/load | unload | save | check
    POST /api/shell/eval | reset
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

  def call(%{method: "GET", request_path: "/shell"} = conn, _opts),
    do: html(conn, shell_page())

  # ---- POST ----

  def call(%{method: "POST"} = conn, _opts) do
    case conn.request_path |> String.split("/") do
      ["", "api", "flows", name, "load"] ->
        reply(conn, HomeElixir.FlowStore.load(name))

      ["", "api", "flows", name, "unload"] ->
        reply(conn, HomeElixir.FlowStore.unload(name))

      ["", "api", "flows", name, "save"] ->
        save_endpoint(conn, name)

      ["", "api", "flows", _, "check"] ->
        check_endpoint(conn)

      ["", "api", "shell", "eval"] ->
        text(conn, 200, HomeElixir.Shell.eval(body(conn)))

      ["", "api", "shell", "reset"] ->
        text(conn, 200, HomeElixir.Shell.reset())

      _ ->
        not_found(conn)
    end
  end

  def call(conn, _opts), do: not_found(conn)

  # ---- handlers ----

  defp save_endpoint(conn, name) do
    source = body(conn)

    try do
      save_flow(name, source)
      reply(conn, :ok)
    rescue
      e ->
        text(conn, 400, "saved, but reload failed:\n" <> Exception.message(e))
    end
  end

  defp check_endpoint(conn) do
    case HomeElixir.FlowStore.check(body(conn)) do
      {:ok, msg} -> text(conn, 200, msg)
      {:error, msg} -> text(conn, 400, msg)
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
  defp not_found(conn), do: json(conn, %{error: "not found"}) |> put_status(404)

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:error, reason}), do: conn |> put_status(400) |> json(%{error: reason})
  defp reply(conn, other), do: json(conn, other)

  # ---- pages ----

  defp list_page do
    """
    #{base_html("Flows")}
      <table id="flows"></table>
      <p><a href="/edit">New flow</a> &nbsp;·&nbsp; <a href="/shell">Dev shell</a></p>
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

  defp editor_page(name, source) do
    name_json = Jason.encode!(name || "")
    source_json = Jason.encode!(source)

    """
    #{base_html("Edit flow")}
      <p><label>Name <input id="name" value=#{name_json}></label>
         <button id="check">Check</button>
         <button id="save">Save</button>
         <span id="status"></span></p>
      <textarea id="editor" spellcheck="false"></textarea>
      <pre class="preview"><code id="preview" class="language-elixir"></code></pre>
      <script src="#{@hljs}/highlight.min.js"></script>
      <script src="#{@hljs}/languages/elixir.min.js"></script>
      <script>
        const FLOW = { name: #{name_json}, source: #{source_json} };
        const nameEl = document.getElementById("name");
        const editor = document.getElementById("editor");
        const preview = document.getElementById("preview");
        const status = document.getElementById("status");
        nameEl.value = FLOW.name;
        editor.value = FLOW.source;
        function render() {
          preview.textContent = editor.value;
          hljs.highlightElement(preview);
        }
        editor.addEventListener("input", render);
        render();
        const name = () => nameEl.value.trim();
        const src = () => editor.value;
        async function doSave() {
          const r = await fetch(`/api/flows/${encodeURIComponent(name())}/save`, { method: "POST", body: src() });
          status.textContent = (await r.text()) || "saved";
        }
        async function doCheck() {
          const r = await fetch(`/api/flows/${encodeURIComponent(name())}/check`, { method: "POST", body: src() });
          status.textContent = await r.text();
        }
        document.getElementById("save").onclick = doSave;
        document.getElementById("check").onclick = doCheck;
      </script>
    """
  end

  defp shell_page do
    """
    #{base_html("Dev shell", dark: true)}
      <div id="out"></div>
      <div class="prompt">iex&gt; <input id="in" autocomplete="off" autofocus></div>
      <script>
        const out = document.getElementById("out");
        const inp = document.getElementById("in");
        function add(t) { out.textContent += t + "\\n"; out.scrollTop = out.scrollHeight; }
        async function reset() { add(await (await fetch("/api/shell/reset")).text()); }
        async function send() {
          const line = inp.value; inp.value = "";
          if (!line) return;
          add("> " + line);
          add(await (await fetch("/api/shell/eval", { method: "POST", body: line })).text());
        }
        inp.addEventListener("keydown", e => { if (e.key === "Enter") send(); });
        reset();
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
        #editor { width: 100%; box-sizing: border-box; height: 40vh; min-height: 220px;
                  font: 13px/1.5 ui-monospace, monospace; padding: .6rem;
                  border: 1px solid #ccc; white-space: pre; overflow: auto;
                  tab-size: 2; }
        .preview { margin: 0; padding: .6rem; background: #f6f8fa; border: 1px solid #ccc;
                   border-top: none; max-height: 40vh; overflow: auto; }
        .preview code { font: 13px/1.5 ui-monospace, monospace; white-space: pre; }
        #status { margin-left: .8rem; color: #0a7a2f; }
      </style>
    </head>
    <body>
    """
  end
end
