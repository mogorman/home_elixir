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
    POST /api/flows/save | check   (save reuses the editor's path via the X-Flow-Name header; new files derive it from the module)
  """

  @behaviour Plug

  import Plug.Conn
  require Logger
  alias HomeElixir.Template

  @hljs "static/hljs"
  @bootstrap "static/ha.css"

  def init(_opts), do: []

  # Entry point (behaviour). Serves the app under an optional base path so it
  # works both at the site root (direct port) and under a reverse proxy / HA
  # ingress prefix (`/api/ingress/<uuid>/`). The prefix is detected from the
  # request, stripped for routing, and stashed in `assigns[:base]` so emitted
  # URLs (and `<base href>`) can be re-rooted. Everything below routes on the
  # prefix-less path via `dispatch/2`.
  def call(conn, opts) do
    base = base_path(conn.request_path)
    rel = if base == "", do: conn.request_path, else: String.replace_prefix(conn.request_path, base, "")
    rel = if rel == "" or rel == nil, do: "/", else: rel

    conn
    |> Map.put(:request_path, rel)
    |> assign(:base, base)
    |> dispatch(opts)
  end

  # Detects a leading ingress/proxy base: `/api/ingress/<uuid>` (the only
  # prefix this app is served under) or nothing. Public so the AuthGuard can
  # judge public-ness on the prefix-less path.
  def base_path(path) do
    case Regex.run(~r{^/api/(?:hassio_)?ingress/[^/]+}, path || "") do
      [b] -> b
      _ -> ""
    end
  end

  # Behind HA ingress the supervisor strips the prefix, so absolute paths
  # (/login, /) escape to the HA root. Use relative paths instead.
  def ingress?(conn), do: get_req_header(conn, "x-ingress") != []
  def home_path(conn), do: if(ingress?(conn), do: ".", else: "/")
  def login_path(conn), do: if(ingress?(conn), do: "login", else: "/login")

  # ---- GET ----

  # Public (bypasses the guard): shown when not logged in, redirects when logged in.
  def dispatch(%{method: "GET", request_path: "/login"} = conn, _opts) do
    case HomeElixir.Auth.user_from_conn(conn) do
      {:ok, _} -> redirect(conn, to: home_path(conn))
      _ -> html(conn, login_page())
    end
  end

  # Public OAuth entry: begin the HA local-OAuth flow and send the browser to
  # HA's authorize page. Bounces back to /login when HA is not configured.
  def dispatch(%{method: "GET", request_path: "/oauth/start"} = conn, _opts) do
    case HomeElixir.HA.OAuth.start_login() do
      {:ok, url, _state} -> redirect(conn, to: url)
      {:error, _reason} -> redirect(conn, to: "/login")
    end
  end

  # Public OAuth callback: exchange the code for a token, resolve the user via
  # HA, set the session cookie, and redirect home.
  def dispatch(%{method: "GET", request_path: "/oauth/callback"} = conn, _opts) do
    q = URI.decode_query(conn.query_string)

    case q do
      %{"error" => _err} ->
        redirect(conn, to: "/login")

      %{"code" => code, "state" => state} ->
        finish_oauth(conn, HomeElixir.HA.OAuth.complete_login(code, state))

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def dispatch(%{method: "GET", request_path: "/"} = conn, _opts),
    do: html(conn, list_page(cur(conn), :flows))

  def dispatch(%{method: "GET", request_path: "/archived"} = conn, _opts),
    do: html(conn, list_page(cur(conn), :archived))

  def dispatch(%{method: "GET", request_path: "/examples"} = conn, _opts),
    do: html(conn, list_page(cur(conn), :examples))

  def dispatch(%{method: "GET", request_path: "/examples/" <> name} = conn, _opts) do
    if flow_name_valid?(name) do
      case HomeElixir.Examples.source(name) do
        {:ok, src} -> html(conn, example_view_page(name, src, cur(conn)))
        _ -> not_found(conn)
      end
    else
      not_found(conn)
    end
  end

  def dispatch(%{method: "GET", request_path: "/docs"} = conn, _opts),
    do: html(conn, docs_page(cur(conn)))

  # The bundled docs source, served raw so the /docs page can render it client-side.
  def dispatch(%{method: "GET", request_path: "/docs.md"} = conn, _opts) do
    case File.read(docs_path()) do
      {:ok, md} -> text(conn, 200, md)
      _ -> not_found(conn)
    end
  end

  def dispatch(%{method: "GET", request_path: "/reference"} = conn, _opts),
    do: html(conn, reference_page(cur(conn)))

  # The module reference source, served raw so the /reference page renders it client-side.
  def dispatch(%{method: "GET", request_path: "/reference.md"} = conn, _opts) do
    case File.read(reference_path()) do
      {:ok, md} -> text(conn, 200, md)
      _ -> not_found(conn)
    end
  end

  def dispatch(%{method: "GET", request_path: "/api/flows"} = conn, _opts) do
    case HomeElixir.FlowStore.list() do
      flows -> json(conn, visible_flows(conn, flows))
      :timeout -> json(conn, %{"busy" => true, "message" => "Installing flow dependencies…"})
    end
  end

  def dispatch(%{method: "GET", request_path: "/api/examples"} = conn, _opts) do
    json(conn, HomeElixir.Examples.list() |> Enum.map(& &1.name))
  end

  def dispatch(%{method: "GET", request_path: "/api/me"} = conn, _opts) do
    case cur(conn) do
      {name, role} -> json(conn, %{name: name, role: role})
      _ -> json(conn, %{name: nil, role: nil})
    end
  end

  # User management (admin only).
  def dispatch(%{method: "GET", request_path: "/admin"} = conn, _opts) do
    if is_admin?(conn), do: html(conn, admin_page(cur(conn))), else: forbidden(conn)
  end

  # Global config editor (admin only).
  def dispatch(%{method: "GET", request_path: "/config"} = conn, _opts) do
    if is_admin?(conn), do: html(conn, config_page(cur(conn))), else: forbidden(conn)
  end

  def dispatch(%{method: "GET", request_path: "/api/admin/users"} = conn, _opts) do
    if is_admin?(conn), do: json(conn, HomeElixir.Auth.list_users()), else: forbidden(conn)
  end

  def dispatch(%{method: "GET", request_path: "/api/entity_tree"} = conn, _opts),
    do: json(conn, HomeElixir.EntityBrowser.tree())

  # Global config (admin only).
  def dispatch(%{method: "GET", request_path: "/api/config"} = conn, _opts) do
    if is_admin?(conn), do: json(conn, global_config_payload()), else: forbidden(conn)
  end

  def dispatch(%{method: "GET", request_path: "/controls"} = conn, _opts),
    do: html(conn, controls_page(cur(conn)))

  def dispatch(%{method: "GET", request_path: "/api/ui"} = conn, _opts),
    do: json(conn, visible_ui(conn))

  # Live UI updates over a web socket (pushes state-badge changes to the browser).
  def dispatch(%{method: "GET", request_path: "/api/ui/ws"} = conn, _opts) do
    if websocket?(conn), do: upgrade_to_ui_ws(conn), else: text(conn, 400, "web socket only")
  end

  def dispatch(%{method: "GET", request_path: "/api/flows/download-all"} = conn, _opts) do
    download_all_endpoint(conn)
  end

  # Download a full-state backup (admin only): flow sources + config + users + flow state.
  def dispatch(%{method: "GET", request_path: "/api/backup"} = conn, _opts) do
    if is_admin?(conn) do
      doc = HomeElixir.Backup.snapshot()
      download_json(conn, "home-elixir-backup.json", Jason.encode!(doc, pretty: true), "application/json")
    else
      forbidden(conn)
    end
  end

  def dispatch(%{method: "GET", request_path: "/api/flows/" <> rest} = conn, _opts) do
    # Flow names may be path-style ("LivingRoom/counter"), so only the last
    # segment is the sub-route.
    parts = String.split(rest, "/")
    name = Enum.join(Enum.drop(parts, -1), "/")

    # Reject names that aren't valid flow paths (blocks ../ traversal) and
    # enforce per-flow access, matching the /edit route.
    cond do
      length(parts) < 2 or not flow_name_valid?(name) ->
        not_found(conn)

      true ->
        with :ok <- flow_access(conn, name) do
          case List.last(parts) do
            "ui" ->
              json(conn, HomeElixir.FlowStore.flow_ui(name))

            "config" ->
              json(conn, flow_config_payload(name))

            "loaded_source" ->
              case HomeElixir.FlowStore.loaded_source(name) do
                {:ok, src} -> json(conn, %{source: src})
                :error -> not_found(conn)
              end

            "download" ->
              case File.read(flow_path(name)) do
                {:ok, source} -> download_json(conn, Path.basename(name) <> ".ex", source, "text/x-elixir")
                _ -> not_found(conn)
              end

            _ ->
              not_found(conn)
          end
        else
          _ -> forbidden(conn)
        end
    end
  end

  def dispatch(%{method: "GET", request_path: "/edit"} = conn, _opts),
    do: html(conn, editor_page(nil, new_flow_template(), cur(conn)))

  def dispatch(%{method: "GET", request_path: "/edit/" <> name} = conn, _opts) do
    # Relative static URLs from the editor page resolve as /edit/static/...
    if String.contains?(name, "/static/") do
      rest = String.split(name, "/static/", parts: 2) |> Enum.at(1)
      static_file(conn, rest)
    else
      if flow_name_valid?(name) do
        case flow_access(conn, name) do
          :ok -> html(conn, editor_page(name, read_flow(name), cur(conn)))
          _ -> forbidden(conn)
        end
      else
        not_found(conn)
      end
    end
  end

  # Full log view is admin-only; per-flow log panels use the filtered /api/logs.
  def dispatch(%{method: "GET", request_path: "/logs"} = conn, _opts) do
    if is_admin?(conn), do: html(conn, logs_page(cur(conn))), else: forbidden(conn)
  end

  def dispatch(%{method: "GET", request_path: "/api/logs"} = conn, _opts) do
    lines = HomeElixir.Log.lines(parse_since(conn.query_string))
    json(conn, log_entries(lines, conn))
  end

  # In-browser IEx: admin only (it can run arbitrary code on the app node).
  def dispatch(%{method: "GET", request_path: "/terminal"} = conn, _opts) do
    if is_admin?(conn) do
      if websocket?(conn),
        do: upgrade_to_terminal(conn),
        else: html(conn, terminal_page(cur(conn)))
    else
      forbidden(conn)
    end
  end

  def dispatch(%{method: "GET", request_path: "/favicon.ico"} = conn, _opts),
    do: static_file(conn, "favicon.ico")

  def dispatch(%{method: "GET", request_path: "/static/" <> rest} = conn, _opts),
    do: static_file(conn, rest)

  def dispatch(%{method: "GET"} = conn, _opts), do: not_found(conn)

  # ---- POST ----

  def dispatch(%{method: "POST"} = conn, _opts) do
    case conn.request_path |> String.split("/") do
      ["", "api", "login"] ->
        login_endpoint(conn)

      ["", "api", "logout"] ->
        logout_endpoint(conn)

      ["", "api", "admin", "users"] ->
        if is_admin?(conn), do: admin_create_user(conn), else: forbidden(conn)

      ["", "api", "admin", "users", name, action] ->
        if is_admin?(conn), do: admin_user_action(conn, name, action), else: forbidden(conn)

      ["", "api", "config"] ->
        global_config_set_endpoint(conn)

       # Import a .zip of flows (raw body); lands each .ex by its defmodule name.
       ["", "api", "flows", "import"] ->
         import_endpoint(conn)

       # Restore a full-state backup (admin only): JSON body from /api/backup.
       ["", "api", "restore"] ->
         restore_endpoint(conn)

       # Flow names may be path-style ("LivingRoom/counter"), so the name is
       # everything between "flows" and the trailing action segment.
       ["", "api", "flows" | tail] when length(tail) >= 1 ->
         flow_api(conn, Enum.join(Enum.drop(tail, -1), "/"), List.last(tail))

       # Copy a bundled example into the user's flows (examples have flat names).
       ["", "api", "examples", name, "copy"] ->
         copy_example_endpoint(conn, name)


       ["", "api", "ui", "click"] ->
         click_endpoint(conn)

       ["", "api", "nodered", "dismiss"] ->
         nodered_dismiss_endpoint(conn)

       ["", "api", "nodered", "check"] ->
         if is_admin?(conn), do: nodered_check_endpoint(conn), else: forbidden(conn)

       _ ->
         not_found(conn)
    end
  end

  defp flow_api(conn, name, action) do
    # "save"/"check" use an empty name (the path comes from the header/source);
    # every other action is keyed by a flow name, which must be a valid path
    # (blocks ../ traversal into resolve/compile).
    if name != "" and not flow_name_valid?(name) do
      bad_request(conn, "invalid flow name")
    else
      case {name, action} do
        {"", "save"} ->
          save_endpoint(conn)

        {"", "check"} ->
          check_endpoint(conn)

        # "reload all" touches every loaded flow, so admin only.
        {"", "reload"} ->
          if is_admin?(conn) do
            reply(conn, HomeElixir.FlowStore.reload_all())
          else
            reply(conn, {:error, "forbidden"})
          end

        {name, "load"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.load(name) end))

        {name, "unload"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.unload(name) end))

        {name, "reload"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.reload(name) end))

        {name, "archive"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.archive(name) end))

        {name, "unarchive"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.unarchive(name) end))

        {name, "delete"} ->
          reply(conn, guard_flow(conn, name, fn -> HomeElixir.FlowStore.delete(name) end))

        {name, "clone"} ->
          # clone returns {:ok, new_name}; the client only needs to refresh.
          reply(conn,
            guard_flow(conn, name, fn ->
              case HomeElixir.FlowStore.clone(name) do
                {:ok, _} -> :ok
                {:error, reason} -> {:error, reason}
              end
            end))

        # Change a flow's owner (admin only): a username, "public" (all users),
        # or null (unowned / admin-only).
        {name, "owner"} ->
          if is_admin?(conn) do
            set_flow_owner_endpoint(conn, name)
          else
            reply(conn, {:error, "forbidden"})
          end

        # Set/reset a config value for this flow (or a global value, admin only).
        {name, "config"} ->
          flow_config_set_endpoint(conn, name)

        _ ->
          not_found(conn)
      end
    end
  end

  defp set_flow_owner_endpoint(conn, name) do
    with {:ok, %{"owner" => raw}} <- Jason.decode(body(conn)),
         :ok <- valid_owner?(raw) do
      case raw do
        nil -> HomeElixir.FlowState.clear_flow_owner(name)
        owner -> HomeElixir.FlowState.set_flow_owner(name, owner)
      end

      reply(conn, :ok)
    else
      {:error, :bad_owner} ->
        bad_request(conn, "owner must be null, \"public\", or an existing user")

      _ ->
        reply(conn, {:error, "owner required"})
    end
  end

  # An owner is null (unowned/admin-only), the all-users sentinel, or a real
  # username — nothing else (a stray value would orphan the flow).
  defp valid_owner?(nil), do: :ok
  defp valid_owner?("public"), do: :ok

  defp valid_owner?(owner) when is_binary(owner) do
    if HomeElixir.Auth.list_users() |> Enum.any?(&(&1.name == owner)) do
      :ok
    else
      {:error, :bad_owner}
    end
  end

  defp valid_owner?(_), do: {:error, :bad_owner}

  # Run a per-flow action only if the current user may touch that flow.
  defp guard_flow(conn, name, fun) do
    case flow_access(conn, name) do
      :ok -> fun.()
      _ -> {:error, "forbidden"}
    end
  end

  # Copy a bundled example into the user's flows (verbatim). The new flow is
  # idle and editable; the client navigates to its editor.
  defp copy_example_endpoint(conn, name) do
    if flow_name_valid?(name) do
      case HomeElixir.Examples.copy(name) do
        {:ok, new_name} ->
          HomeElixir.UI.Hub.push(:flow_changed, %{})
          json(conn, %{ok: true, name: new_name})

        {:error, :exists} ->
          bad_request(conn, "a flow named #{name} already exists")

        {:error, :not_found} ->
          not_found(conn)
      end
    else
      bad_request(conn, "invalid name")
    end
  end

  # ---- handlers ----

  defp save_endpoint(conn) do
    source = body(conn)
    header = List.first(get_req_header(conn, "x-flow-name"))

    case name_from_source(source) do
      nil ->
        text(conn, 400, "could not find a `defmodule` in the source")

      new_name ->
        # The editor sends the path it was opened on. If the source's module now
        # implies a different name, this is a rename: the file moves to the new
        # name (and the old one is dropped).
        old_name =
          case header do
            n when n in [nil, ""] -> nil
            n -> if flow_name_valid?(n) and File.exists?(flow_path(n)), do: n, else: nil
          end

        renaming? = old_name != nil and old_name != new_name

        with :ok <- save_guard(conn, old_name || new_name),
             :ok <- rename_collision?(old_name, new_name) do
          # New flows claim their owner on first save; a rename carries the
          # original's owner in FlowStore.rename, so don't reassign here.
          unless renaming?,
            do: HomeElixir.FlowState.assign_owner_if_new(new_name, elem(cur(conn), 0))

          try do
            save_flow(new_name, source)
            if renaming?, do: HomeElixir.FlowStore.rename(old_name, new_name)
            HomeElixir.UI.Hub.push(:flow_changed, %{})

            # Save persists the file. A flow that's already running is left as-is
            # (no reload, so its setup/dep install isn't re-run — hit Reload to
            # pick up the new source); one that isn't running is loaded now (setup
            # runs on load).
            case HomeElixir.FlowStore.loaded?(new_name) do
              true ->
                text(conn, 200, "saved " <> new_name <> ".ex (already running)")

              false ->
                case HomeElixir.FlowStore.load(new_name) do
                  :ok -> text(conn, 200, "saved " <> new_name <> ".ex (loaded)")
                  {:error, reason} ->
                    text(conn, 400, "saved " <> new_name <> ".ex, but could not load:\n" <>
                                       to_string(reason))
                end
            end
          rescue
            e ->
              text(
                conn,
                400,
                "saved " <> new_name <> ".ex, but save failed:\n" <> Exception.message(e)
              )
          end
        else
          {:error, msg} -> text(conn, 400, msg)
        end
    end
  end

  # New flows may be created by anyone logged in; an existing flow may be saved
  # only by its owner or an admin. Unowned pre-existing files are admin-only.
  defp save_guard(conn, name) do
    case cur(conn) do
      {_id, "admin"} ->
        :ok

      {id, _} ->
        cond do
          not File.exists?(flow_path(name)) -> :ok
          HomeElixir.FlowState.flow_owner(name) == id -> :ok
          true -> {:error, "forbidden: not your flow"}
        end

      _ ->
        :ok
    end
  end

  # A rename must not clobber a different flow that already has the new name.
  # Saving the same name (old == new) is just an update, not a collision.
  defp rename_collision?(nil, _new), do: :ok
  defp rename_collision?(old, new) when old == new, do: :ok

  defp rename_collision?(_old, new),
    do:
      if(File.exists?(flow_path(new)),
        do: {:error, "a flow named #{new} already exists"},
        else: :ok
      )

  defp flow_name_valid?(name), do: Regex.match?(~r/^[A-Za-z0-9_]+(?:\/[A-Za-z0-9_]+)*$/, name)

  # Derive the flow file name from the module name in the source (single source
  # of truth, so the name and module can't drift apart). A
  # `HomeElixir.Flows.LivingRoom.Counter` module maps to "LivingRoom/counter".
  def name_from_source(source) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source) do
      [_, mod] ->
        case String.split(mod, ".") do
          ["HomeElixir", "Flows" | rest] ->
            {dirs, [leaf]} = Enum.split(rest, length(rest) - 1)
            Enum.join(dirs ++ [Macro.underscore(leaf)], "/")

          parts ->
            parts |> List.last() |> Macro.underscore()
        end

      _ ->
        nil
    end
  end

  defp check_endpoint(conn) do
    case HomeElixir.FlowStore.check(body(conn)) do
      {:ok, msg} -> text(conn, 200, msg)
      {:error, msg} -> text(conn, 400, msg)
    end
  end

  # ---- download / import (flow files) ----

  # Bundle the caller's visible flows (name => source) and send it in the
  # requested format (?format=zip|tar|json, default zip).
  defp download_all_endpoint(conn) do
    flows =
      case HomeElixir.FlowStore.list() do
        :timeout -> []
        list -> visible_flows(conn, list)
      end

    pairs = for f <- flows, {:ok, src} <- [File.read(f.path)], into: [], do: {f.name, src}

    format =
      conn
      |> Map.get(:query_string, "")
      |> URI.decode_query()
      |> Map.get("format", "zip")
      |> HomeElixir.Bundle.parse_format()

    case HomeElixir.Bundle.produce(pairs, format) do
      {:ok, {bytes, filename, ctype}} -> download_json(conn, filename, bytes, ctype)
      {:error, reason} -> bundle_error(conn, format, reason)
    end
  end

  # Import a bundle of flows. The format is declared in the x-bundle-format header
  # (zip|tar|json). Each source lands by its defmodule name under the same
  # per-flow rules as save; written, not loaded.
  defp import_endpoint(conn) do
    format =
      (List.first(get_req_header(conn, "x-bundle-format")) || "")
      |> HomeElixir.Bundle.parse_format()

    case format do
      :none ->
        bad_request(conn, "x-bundle-format must be zip, tar, or json")

      _ ->
        case HomeElixir.Bundle.consume(body(conn), format) do
          {:ok, pairs} -> json(conn, Map.put(do_import(pairs, cur(conn)), "ok", true))
          {:error, reason} -> bundle_error(conn, format, reason)
        end
    end
  end

  # A bundle error: 400 for a bad/unparseable archive, 501 when the format isn't
  # available in this build (e.g. :zip absent from the OTP).
  defp bundle_error(conn, format, reason) do
    status = if HomeElixir.Bundle.available?(format), do: 400, else: 501
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(%{error: reason}))
  end

  # Restore a full-state backup (admin only). Body is the JSON from /api/backup.
  defp restore_endpoint(conn) do
    unless is_admin?(conn) do
      forbidden(conn)
    else
      case Jason.decode(body(conn)) do
        {:ok, doc} ->
          if is_map(doc) and doc["home_elixir_backup"] do
            summary = HomeElixir.Backup.restore(doc)
            HomeElixir.UI.Hub.push(:flow_changed, %{})
            json(conn, summary)
          else
            bad_request(conn, "not a HomeElixir backup")
          end

        _ ->
          bad_request(conn, "invalid JSON backup")
      end
    end
  end

  # Write each imported source, applying the same per-flow rules as save (new =
  # anyone, existing = owner/admin). Returns a summary of created/updated/skipped.
  defp do_import(pairs, user) do
    Enum.reduce(pairs, %{created: 0, updated: 0, skipped: []}, fn {label, src}, acc ->
      case name_from_source(src) do
        nil ->
          Map.update(acc, :skipped, [], & &1 ++ [%{name: label, reason: "no defmodule"}])

        name ->
          exists = File.exists?(flow_path(name))

          case import_perm(user, name) do
            :ok ->
              save_flow(name, src)
              unless exists, do: HomeElixir.FlowState.assign_owner_if_new(name, elem(user, 0))
              HomeElixir.UI.Hub.push(:flow_changed, %{})
              Map.update(acc, if(exists, do: :updated, else: :created), 0, &(&1 + 1))

            {:error, reason} ->
              Map.update(acc, :skipped, [], & &1 ++ [%{name: name, reason: reason}])
          end
      end
    end)
  end

  # Can this user create/overwrite a flow by this name? Same rules as save_guard.
  defp import_perm({_id, "admin"}, _name), do: :ok

  defp import_perm({id, _}, name) do
    cond do
      not File.exists?(flow_path(name)) -> :ok
      HomeElixir.FlowState.flow_owner(name) == id -> :ok
      true -> {:error, "not your flow"}
    end
  end

  defp import_perm(_, _), do: :ok

  # ---- config endpoints ----

  # A flow's config for the UI: the union of its own keys and the global keys,
  # each with its effective value, whether it's flow- or global-scoped, and a
  # secret flag so the client can mask it.
  defp flow_config_payload(name) do
    flow = HomeElixir.Config.flow_config(name)
    global = HomeElixir.Config.global_config()

    (Map.keys(flow) ++ Map.keys(global))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn key ->
      fv = Map.get(flow, key)
      gv = Map.get(global, key)

      %{
        key: key,
        value: if(is_nil(fv), do: gv, else: fv),
        source: if(is_nil(fv), do: "global", else: "flow"),
        secret: HomeElixir.Config.secret?(key),
        flow_value: fv,
        global_value: gv
      }
    end)
  end

  defp global_config_payload do
    HomeElixir.Config.global_config()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key ->
      %{key: key, value: Map.get(HomeElixir.Config.global_config(), key), secret: HomeElixir.Config.secret?(key)}
    end)
  end

  # Set (value) or reset (value null) a config key for a flow or globally.
  defp flow_config_set_endpoint(conn, name) do
    case Jason.decode(body(conn)) do
      {:ok, %{"key" => key} = data} when is_binary(key) and key != "" ->
        reply(conn, config_set(conn, name, key, data["value"], data["scope"] || "flow"))

      _ ->
        bad_request(conn, "key required")
    end
  end

  defp config_set(conn, _name, key, value, "global") do
    if is_admin?(conn) do
      apply_config(:global, key, value)
    else
      {:error, "forbidden: global config is admin-only"}
    end
  end

  defp config_set(conn, name, key, value, _scope) do
    case flow_access(conn, name) do
      :ok -> apply_config(name, key, value)
      _ -> {:error, "forbidden"}
    end
  end

  # Global config (admin only): set or reset a key.
  defp global_config_set_endpoint(conn) do
    if is_admin?(conn) do
      case Jason.decode(body(conn)) do
        {:ok, %{"key" => key} = data} when is_binary(key) and key != "" ->
          apply_config(:global, key, data["value"])
          json(conn, %{ok: true})

        _ ->
          bad_request(conn, "key required")
      end
    else
      forbidden(conn)
    end
  end

  # value nil means "reset" (remove the override so reads fall back).
  defp apply_config(scope, key, nil) do
    HomeElixir.Config.delete(scope, key)
    HomeElixir.UI.Hub.push(:flow_changed, %{})
    :ok
  end

  defp apply_config(scope, key, value) do
    HomeElixir.Config.put(scope, key, value)
    HomeElixir.UI.Hub.push(:flow_changed, %{})
    :ok
  end

  defp click_endpoint(conn) do
    case Jason.decode(body(conn)) do
      {:ok, %{"name" => name, "node" => node} = data} when is_binary(name) and is_binary(node) ->
        if flow_name_valid?(name) do
          reply(
            conn,
            guard_flow(conn, name, fn ->
              HomeElixir.FlowStore.click(name, node, Map.get(data, "payload"))
            end)
          )
        else
          bad_request(conn, "invalid flow name")
        end

      {:ok, _} ->
        conn |> put_status(400) |> json(%{error: "name and node required"})

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid json body"})
    end
  end

  # ---- auth + admin endpoints ----

  # Accepts {username, password}; on success sets the session cookie and
  # redirects home.
  defp login_endpoint(conn) do
    case Jason.decode(body(conn)) do
      {:ok, data} ->
        result = HomeElixir.Auth.login(data["username"] || "", data["password"] || "")

        case result do
          {:ok, {uid, role}} ->
            token = HomeElixir.Auth.create_session(uid, role)

            conn
            |> put_resp_cookie(HomeElixir.Auth.cookie_name(), token, cookie_opts())
            |> redirect(to: "/")

          {:error, reason} ->
            unauthorized(conn, error_message(reason))
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid json body"})
    end
  end

  # OAuth callback success: resolve the token's user and open a session. The
  # token itself becomes the shared HA auth (flows + WS client use it).
  defp finish_oauth(conn, {:ok, token}) do
    case HomeElixir.Auth.login_ha_token(token) do
      {:ok, {uid, role}} ->
        HomeElixir.HA.activate(token)
        session = HomeElixir.Auth.create_session(uid, role)

        conn
        |> put_resp_cookie(HomeElixir.Auth.cookie_name(), session, cookie_opts())
        |> redirect(to: home_path(conn))

      err ->
        Logger.warning("oauth: token ok but identity failed: #{inspect(err)}")
        redirect(conn, to: login_path(conn))
    end
  end

  defp finish_oauth(conn, {:error, reason}) do
    Logger.warning("oauth: complete_login failed: #{inspect(reason)}")
    redirect(conn, to: login_path(conn))
  end

  defp logout_endpoint(conn) do
    if token = conn.cookies[HomeElixir.Auth.cookie_name()] do
      HomeElixir.Auth.delete_session(token)
    end

    conn
    |> delete_resp_cookie(HomeElixir.Auth.cookie_name(), path: "/", sign: false)
    |> redirect(to: "/login")
  end

  # Dismiss the "add Node-RED Companion" notice. Any authenticated user can do
  # this (they're the ones who see it); the flag is global, so it stays dismissed.
  defp nodered_dismiss_endpoint(conn) do
    HomeElixir.Config.put_global(:nodered_notice_dismissed, true)
    json(conn, %{ok: true})
  end

  # Admin: re-run the Node-RED Companion probe now and return the fresh status.
  defp nodered_check_endpoint(conn) do
    json(conn, %{status: HomeElixir.NodeRedStatus.recheck()})
  end

  # Create a user (admin only — the /admin page is the only UI that reaches this,
  # and the route itself is behind the auth guard).
  defp admin_create_user(conn) do
    with {:ok, %{"name" => name, "password" => password} = data}
         when name != "" and password != "" <-
           Jason.decode(body(conn)) do
      role = if data["role"] in ~w(admin user), do: data["role"], else: "user"

      case HomeElixir.Auth.create_user(name, password, role) do
        :ok -> json(conn, %{ok: true})
        {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
      end
    else
      _ -> conn |> put_status(400) |> json(%{error: "name and password required"})
    end
  end

  defp admin_user_action(conn, name, action) do
    case action do
      "delete" ->
        case HomeElixir.Auth.delete_user(name) do
          :ok -> json(conn, %{ok: true})
          {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
        end

      "role" ->
        with {:ok, %{"role" => role}} <- Jason.decode(body(conn)) do
          case HomeElixir.Auth.set_role(name, role) do
            :ok -> json(conn, %{ok: true})
            {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
          end
        else
          _ -> conn |> put_status(400) |> json(%{error: "role required"})
        end

      "reset" ->
        with {:ok, %{"password" => password}} when password != "" <- Jason.decode(body(conn)) do
          case HomeElixir.Auth.reset_password(name, password) do
            :ok -> json(conn, %{ok: true})
            {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
          end
        else
          _ -> conn |> put_status(400) |> json(%{error: "password required"})
        end

      _ ->
        not_found(conn)
    end
  end

  defp cookie_opts do
    [
      http_only: true,
      same_site: "Lax",
      path: "/",
      sign: false,
      max_age: Application.get_env(:home_elixir, :session_ttl_h, 168) * 3600
    ]
  end

  defp error_message(:bad_credentials), do: "invalid username or password"

  defp unauthorized(conn, msg) do
    conn |> put_status(401) |> json(%{error: msg})
  end

  defp parse_since(query) do
    case URI.decode_query(query || "") |> Map.get("since") do
      nil ->
        0

      s ->
        case Integer.parse(s) do
          {n, _} -> n
          :error -> 0
        end
    end
  end

  # ---- flow file ops ----

  defp save_flow(name, source) do
    path = flow_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
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

  # The current user, assigned by HomeElixir.AuthGuard: {username, role} or nil.
  defp cur(conn), do: conn.assigns[:user]
  defp role_of(conn), do: elem(cur(conn) || {"", ""}, 1)
  defp is_admin?(conn), do: role_of(conn) == "admin"

  # A user may open/edit a named flow if they are admin, its owner, or the flow
  # is public (owned by everyone).
  defp flow_access(conn, name) do
    pub = HomeElixir.FlowState.public_owner()

    case cur(conn) do
      {_id, "admin"} ->
        :ok

      {id, _} ->
        case HomeElixir.FlowState.flow_owner(name) do
          ^id -> :ok
          ^pub -> :ok
          _ -> {:error, :forbidden}
        end

      _ ->
        :ok
    end
  end

  # The flows a user may see: everything for admin, their own + public for
  # others. (Unowned flows — never saved through the UI — are admin-only.)
  defp visible_flows(conn, flows) do
    pub = HomeElixir.FlowState.public_owner()

    case cur(conn) do
      {_id, "admin"} -> flows
      {id, _} -> Enum.filter(flows, fn f -> f[:owner] == id or f[:owner] == pub end)
      _ -> flows
    end
  end

  # The set of flow names a user may see (nil = admin, see all). Regular users
  # see their own + public; unowned (admin-only) flows are excluded.
  defp visible_flow_names(conn) do
    case cur(conn) do
      {_id, "admin"} ->
        nil

      {id, _} ->
        pub = HomeElixir.FlowState.public_owner()

        HomeElixir.FlowState.all_flow_owners()
        |> Enum.filter(fn {_n, owner} -> owner == id or owner == pub end)
        |> MapSet.new()

      _ ->
        nil
    end
  end

  # UI controls restricted to flows the user may see, so an admin-only flow's
  # controls can't leak to a user who can't open it.
  defp visible_ui(conn) do
    case visible_flow_names(conn) do
      nil -> HomeElixir.FlowStore.ui()
      names -> Enum.filter(HomeElixir.FlowStore.ui(), fn el -> MapSet.member?(names, el.name) end)
    end
  end

  # Log lines visible to a user: everything for admin, only their flows for
  # others. Lines are tagged "level  [FlowTag] …"; untagged (app) lines are
  # hidden from non-admins.
  defp log_entries(lines, conn) do
    case cur(conn) do
      {_id, "admin"} ->
        Enum.map(lines, fn {id, line} -> %{"id" => id, "line" => line} end)

      {id, _} ->
        # Their flows + public ones (matching visible_flows/flow_access), keyed
        # by the leaf name used as the log tag.
        pub = HomeElixir.FlowState.public_owner()

        tags =
          HomeElixir.FlowState.all_flow_owners()
          |> Enum.filter(fn {_n, owner} -> owner == id or owner == pub end)
          |> Enum.map(fn {n, _o} -> n |> String.split("/") |> List.last() end)
          |> MapSet.new()

        lines
        |> Enum.filter(fn {_i, line} -> (log_tag(line) || "") in tags end)
        |> Enum.map(fn {id, line} -> %{"id" => id, "line" => line} end)

      _ ->
        Enum.map(lines, fn {id, line} -> %{"id" => id, "line" => line} end)
    end
  end

  defp log_tag(line) do
    case Regex.run(~r/^\w+\s+\[([^\]]+)\]/, line) do
      [_, tag] -> tag
      _ -> nil
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
  end

  defp bad_request(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: msg}))
  end

  # This Plug version has no Conn.redirect/2; a 302 is all we need. Internal
  # targets are re-rooted under the base path (ingress/proxy prefix); absolute
  # external URLs (e.g. the HA OAuth authorize page) pass through unchanged.
  defp redirect(conn, to: to) do
    base = conn.assigns[:base] || ""
    loc = if String.starts_with?(to, "http"), do: to, else: base <> to

    conn
    |> put_resp_header("location", loc)
    |> send_resp(302, "")
  end

  defp body(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp html(conn, body) do
    tag = base_tag(conn)
    body = inject_base(body, tag)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> send_resp(200, body)
  end

  # A `<base>` + the JS base constant, injected right after every page's `<head>`
  # so relative URLs (links, scripts, fetch, location) and websockets re-root
  # under the ingress/proxy prefix, or the site root when there is none.
  # Behind HA ingress the supervisor strips the prefix, so we omit the base tag
  # entirely — relative URLs then resolve naturally from the browser's URL.
  defp base_tag(conn) do
    base = conn.assigns[:base] || ""

    if ingress?(conn) do
      # HA strips the ingress prefix server-side, so compute it from the browser
      # URL. document.write is synchronous with parsing, so the <base> is in
      # effect before subsequent <link>/<script> tags resolve their URLs.
      ~s|<script>(function(){var m=location.pathname.match(/^(\\/api\\/(?:hassio_)?ingress\\/[^\\/]+)\\//);window.__BASE__=m?m[1]:'';if(m)document.write('<base href="'+m[1]+'/">')})();</script>|
    else
      ~s|<base href="#{base}/">\n<script>window.__BASE__ = "#{base}";</script>|
    end
  end

  defp inject_base(body, tag) do
    case :binary.split(body, "<head>") do
      [head, rest] -> head <> "<head>" <> tag <> rest
      _ -> body
    end
  end

  defp json(conn, data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(conn.status || 200, Jason.encode!(data))

  defp text(conn, status, data),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(status, data)

  # Send a downloadable file as a JSON envelope {filename, content_type,
  # data(base64)}. No Content-Disposition header: the reverse-proxy in front of
  # HA drops attachment responses (503), so the browser builds the file client-side.
  defp download_json(conn, filename, data, content_type) do
    json(conn, %{filename: filename, content_type: content_type, data: Base.encode64(data)})
  end

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
              ".html" -> "text/html"
              ".svg" -> "image/svg+xml"
              ".png" -> "image/png"
              ".ico" -> "image/x-icon"
              ".woff2" -> "font/woff2"
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

  defp terminal_page(user \\ nil) do
    Template.render("terminal.html.eex",
      bootstrap: @bootstrap,
      theme: Template.render("theme.html.eex"),
      theme_script: Template.render("theme_script.html.eex"),
      nav: navbar_html(:iex, user)
    )
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end

  defp reply(conn, :ok), do: json(conn, %{ok: true})
  defp reply(conn, {:error, reason}), do: conn |> put_status(400) |> json(%{error: reason})
  defp reply(conn, other), do: json(conn, other)

  # ---- pages ----

  defp list_page(user, mode \\ :flows) do
    is_admin = user != nil and elem(user, 1) == "admin"
    examples? = mode == :examples
    title = cond do
      examples? -> "Examples"
      mode == :archived -> "Archived"
      true -> "Flows"
    end

    backup_buttons =
      if is_admin do
        ~s|<button id="backup-all" class="btn btn-sm btn-outline-secondary">Backup</button><button id="restore-all" class="btn btn-sm btn-outline-secondary">Restore</button>|
      else
        ""
      end

    header_buttons =
      cond do
        examples? or mode == :archived -> ""

      true ->
        ~s|<a href="edit" class="btn btn-sm btn-primary">New flow</a><button id="upload-flow" class="btn btn-sm btn-outline-secondary">Upload</button><span class="dropdown"><button id="download-all" class="btn btn-sm btn-outline-secondary">Download all <i class="mdi mdi-chevron-down"></i></button><div class="dropdown-menu dropdown-menu-end" id="download-all-menu"><button class="dropdown-item" data-fmt="zip">Zip</button><button class="dropdown-item" data-fmt="tar">Tar</button><button class="dropdown-item" data-fmt="json">JSON</button></div></span><button id="reload-all" class="btn btn-sm btn-outline-secondary">Reload all</button>| <>
          backup_buttons
      end

    Template.render("list.html.eex",
      base: base_html(title, mode, user),
      title: title,
      header_buttons: header_buttons,
      is_admin: is_admin,
      mode_string: to_string(mode),
      nodered_absent: HomeElixir.NodeRedStatus.status() == :absent,
      nodered_loaded: HomeElixir.NodeRedStatus.status() == :loaded,
      control_js: Template.render("control_js.html.eex")
    )
  end

  defp controls_page(user \\ nil) do
    Template.render("controls.html.eex",
      base: base_html("Controls", :controls, user),
      control_js: Template.render("control_js.html.eex")
    )
  end

  defp editor_page(name, source, user \\ nil) do
    source_json = Jason.encode!(source)
    name_json = Jason.encode!(name)

    Template.render("editor.html.eex",
      base: base_html("Edit flow", :edit, user),
      source_json: source_json,
      name_json: name_json,
      readonly_json: "false",
      example_name_json: "null",
      hljs: @hljs,
      control_js: Template.render("control_js.html.eex")
    )
  end

  # Read-only view of a bundled example's source. The only applicable action is
  # Copy (into the user's flows); the other editor controls are hidden.
  defp example_view_page(name, source, user) do
    Template.render("editor.html.eex",
      base: base_html("Example", :examples, user),
      source_json: Jason.encode!(source),
      name_json: "null",
      readonly_json: "true",
      example_name_json: Jason.encode!(name),
      hljs: @hljs,
      control_js: Template.render("control_js.html.eex")
    )
  end

  defp logs_page(user \\ nil) do
    Template.render("logs.html.eex",
      base: base_html("Logs", :logs, user),
      control_js: Template.render("control_js.html.eex")
    )
  end

  defp config_page(user \\ nil) do
    is_admin = user != nil and elem(user, 1) == "admin"

    Template.render("config.html.eex",
      base: base_html("Config", :config, user),
      is_admin: is_admin,
      control_js: Template.render("control_js.html.eex")
    )
  end

  defp login_page do
    Template.render("login.html.eex",
      bootstrap: @bootstrap,
      theme: Template.render("theme.html.eex"),
      theme_script: Template.render("theme_script.html.eex")
    )
  end

  defp admin_page(user) do
    status = HomeElixir.NodeRedStatus.status()

    Template.render("admin.html.eex",
      base: base_html("Admin", :admin, user),
      nodered_card: nodered_admin_card_html(status)
    )
  end

  # The admin card shown while the Node-RED Companion is absent/unknown, with a
  # manual re-check. `:loaded` (and once re-checked to loaded) renders nothing.
  defp nodered_admin_card_html(status) do
    case status do
      :loaded ->
        version = HomeElixir.NodeRedStatus.version()

        """
        <div class="card mt-3" id="nodered-card">
          <div class="card-body d-flex align-items-center gap-3 flex-wrap">
            <span class="text-success">Node-RED Companion: <strong>detected &amp; working</strong></span>
            <span class="text-secondary small">Confirmed via the integration's API#{if version, do: " (v#{version})", else: ""} — device nodes are enabled.</span>
          </div>
        </div>
        """

      _ ->
        """
        <div class="card mt-3" id="nodered-card">
          <div class="card-header fw-semibold">Home Assistant integrations</div>
          <div class="card-body d-flex align-items-center gap-3 flex-wrap">
            <span>Node-RED Companion: <strong id="nodered-status" class="text-warning-emphasis">#{status}</strong></span>
            <span class="text-secondary small">Required for flows that use Node-RED device nodes — add &amp; enable it under Settings → Devices &amp; Services → Add Integration.</span>
            <button id="nodered-check" class="btn btn-sm btn-outline-secondary">Re-check</button>
          </div>
        </div>
        """
    end
  end

  # The Documentation page: the bundled docs (priv/docs/index.md), rendered
  # client-side by priv/templates/docs.html.eex (marked + highlight.js).
  defp docs_page(user \\ nil) do
    Template.render("docs.html.eex",
      base: base_html("Documentation", :docs, user),
      source: "/docs.md",
      related_href: "reference",
      related_label: "Full API reference — every module & function"
    )
  end

  defp docs_path, do: Application.app_dir(:home_elixir, "priv/docs/index.md") |> Path.expand()

  # The API reference: the full ExDoc module reference (priv/docs/reference.md),
  # rendered client-side the same way. A normal app page, so it inherits the
  # app's base handling, auth, navbar and theming under any access path.
  defp reference_page(user \\ nil) do
    Template.render("docs.html.eex",
      base: base_html("API", :reference, user),
      source: "/reference.md",
      related_href: "docs",
      related_label: "User guide"
    )
  end

  defp reference_path, do: Application.app_dir(:home_elixir, "priv/docs/reference.md") |> Path.expand()

  defp base_html(title, active, user \\ nil) do
    Template.render("base.html.eex",
      title: title,
      bootstrap: @bootstrap,
      theme: Template.render("theme.html.eex"),
      theme_script: Template.render("theme_script.html.eex"),
      nav: navbar_html(active, user),
      notice: nodered_notice_html()
    )
  end

  # The dismissible "add Node-RED Companion" notice. Shown only when the
  # integration is confirmed absent and the user hasn't dismissed it.
  defp nodered_notice_html do
    dismissed = HomeElixir.Config.global_config() |> Map.get("nodered_notice_dismissed", false)

    if HomeElixir.NodeRedStatus.status() == :absent and not dismissed do
      """
      <div class="nodered-notice alert alert-info d-flex align-items-center gap-3">
        <div class="flex-grow-1"><strong>Optional:</strong> the Node-RED Companion isn't installed — flows using Node-RED device nodes won't run until it's added. <a href="https://github.com/zachowj/hass-node-red" target="_blank" rel="noopener">Install from HACS</a>, restart Home Assistant, then add &amp; enable it under Settings → Devices &amp; Services → Add Integration.</div>
        <button type="button" class="btn btn-sm btn-outline-secondary" id="nodered-dismiss">Ignore permanently</button>
      </div>
      <script>
        (function(){var b=document.getElementById("nodered-dismiss");if(b)b.onclick=function(){b.closest(".alert").remove();fetch("api/nodered/dismiss",{method:"POST"}).catch(function(){});};})();
      </script>
      """
    else
      ""
    end
  end

  defp navbar_html(active, user \\ nil) do
    a = fn key -> if key == active, do: " active", else: "" end
    admin? = user != nil and elem(user, 1) == "admin"

    """
    <nav class="navbar navbar-expand-lg app-bar">
      <div class="container-fluid">
        <a class="navbar-brand fw-semibold d-flex align-items-center gap-2" href="./"><img src="static/logo.svg" width="24" height="24" alt="">HomeElixir</a>
        <button class="navbar-toggler" id="nav-toggler" type="button" aria-label="Menu" aria-expanded="false"><span class="navbar-toggler-icon"></span></button>
        <div class="collapse navbar-collapse" id="nav-collapse">
          <ul class="navbar-nav gap-1 flex-wrap">
            <li class="nav-item"><a class="nav-link#{a.(:flows)}" href="./">Flows</a></li>
            <li class="nav-item"><a class="nav-link#{a.(:controls)}" href="controls">Controls</a></li>
            <li class="nav-item"><a class="nav-link#{a.(:archived)}" href="archived">Archived</a></li>
            <li class="nav-item"><a class="nav-link#{a.(:examples)}" href="examples">Examples</a></li>
            <li class="nav-item"><a class="nav-link#{a.(:docs)}" href="docs">Documentation</a></li>
            #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:logs)}" href="logs">Logs</a></li>|, else: ""}
            #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:iex)}" href="terminal">IEx</a></li>|, else: ""}
            #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:config)}" href="config">Config</a></li>|, else: ""}
            #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:admin)}" href="admin">Admin</a></li>|, else: ""}
          </ul>
          <span id="nav-loading" class="navbar-text me-2 d-flex align-items-center gap-1" style="display:none; opacity:0; transition: opacity 0.3s"><div class="spinner-border spinner-border-sm" role="status"></div><small id="nav-loading-text"></small></span>
          #{user_menu_html(user)}
          <button id="theme-toggle" class="btn btn-outline-secondary btn-sm ms-2" aria-label="Toggle theme"><i class="mdi mdi-weather-night"></i></button>
        </div>
      </div>
    </nav>
    <script>
      function showLoading(text) {
        var el = document.getElementById("nav-loading");
        document.getElementById("nav-loading-text").textContent = text || "";
        el.style.display = "flex";
        requestAnimationFrame(function() { el.style.opacity = "1"; });
      }
      function hideLoading() {
        var el = document.getElementById("nav-loading");
        el.style.opacity = "0";
        setTimeout(function() { el.style.display = "none"; }, 300);
      }
      (function () {
        var tog = document.getElementById("nav-toggler");
        var col = document.getElementById("nav-collapse");
        if (tog && col) tog.addEventListener("click", function () {
          var open = col.classList.toggle("show");
          tog.classList.toggle("collapsed", !open);
          tog.setAttribute("aria-expanded", open ? "true" : "false");
        });
        var btn = document.getElementById("theme-toggle");
        var mq = window.matchMedia ? matchMedia("(prefers-color-scheme: light)") : null;
        function theme() { return document.documentElement.getAttribute("data-bs-theme"); }
        function label() { btn.innerHTML = theme() === "dark" ? '<i class="mdi mdi-white-balance-sunny"></i>' : '<i class="mdi mdi-weather-night"></i>'; }
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
        var lo = document.getElementById("logout");
        if (lo) lo.onclick = function () {
          fetch("api/logout", { method: "POST" }).then(function () { location.href = __BASE__ ? __BASE__ + "/login" : "login"; });
        };
      })();
    </script>
    """
  end

  defp user_menu_html(nil), do: ""

  defp user_menu_html({name, role}) do
    badge = if role == "admin", do: ~s|<span class="badge bg-primary ms-1">admin</span>|, else: ""
    # Behind HA ingress the session is HA's, so the app's own "Log out" is useless — hide it.
    logout =
      if Process.get(:he_ingress, false), do: "",
      else: ~s|<button id="logout" class="btn btn-outline-secondary btn-sm ms-2">Log out</button>|

    """
    <span class="navbar-text ms-auto me-2 d-flex align-items-center">
      #{name}#{badge}
      #{logout}
    </span>
    """
  end
end
