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

  @hljs "static/hljs"
  @bootstrap "static/bootstrap/bootstrap.min.css"

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
    case Regex.run(~r{^/api/ingress/[^/]+}, path || "") do
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

  def dispatch(%{method: "GET", request_path: "/api/flows"} = conn, _opts) do
    case HomeElixir.FlowStore.list() do
      flows -> json(conn, visible_flows(conn, flows))
      :timeout -> json(conn, %{"busy" => true, "message" => "Installing flow dependencies…"})
    end
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

  def dispatch(%{method: "GET", request_path: "/api/admin/users"} = conn, _opts) do
    if is_admin?(conn), do: json(conn, HomeElixir.Auth.list_users()), else: forbidden(conn)
  end

  def dispatch(%{method: "GET", request_path: "/api/entity_tree"} = conn, _opts),
    do: json(conn, HomeElixir.EntityBrowser.tree())

  def dispatch(%{method: "GET", request_path: "/controls"} = conn, _opts),
    do: html(conn, controls_page(cur(conn)))

  def dispatch(%{method: "GET", request_path: "/api/ui"} = conn, _opts),
    do: json(conn, visible_ui(conn))

  # Live UI updates over a web socket (pushes state-badge changes to the browser).
  def dispatch(%{method: "GET", request_path: "/api/ui/ws"} = conn, _opts) do
    if websocket?(conn), do: upgrade_to_ui_ws(conn), else: text(conn, 400, "web socket only")
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

            "loaded_source" ->
              case HomeElixir.FlowStore.loaded_source(name) do
                {:ok, src} -> json(conn, %{source: src})
                :error -> not_found(conn)
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
    if flow_name_valid?(name) do
      case flow_access(conn, name) do
        :ok -> html(conn, editor_page(name, read_flow(name), cur(conn)))
        _ -> forbidden(conn)
      end
    else
      not_found(conn)
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

      # Flow names may be path-style ("LivingRoom/counter"), so the name is
      # everything between "flows" and the trailing action segment.
      ["", "api", "flows" | tail] when length(tail) >= 1 ->
        flow_api(conn, Enum.join(Enum.drop(tail, -1), "/"), List.last(tail))

      ["", "api", "ui", "click"] ->
        click_endpoint(conn)

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

  def dispatch(conn, _opts), do: not_found(conn)

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
            text(conn, 200, "saved " <> new_name <> ".ex (reload to apply)")
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
  defp rename_collision?(nil, _new), do: :ok

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

  # OAuth callback success: resolve the token's user and open a session.
  defp finish_oauth(conn, {:ok, token}) do
    case HomeElixir.Auth.login_ha_token(token) do
      {:ok, {uid, role}} ->
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

    if ingress?(conn) and base == "" do
      ~s|<script>window.__BASE__ = "";</script>|
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

  defp terminal_page(user \\ nil) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Home Elixir IEx</title>
      <link href="#{@bootstrap}" rel="stylesheet">
      <link rel="stylesheet" href="static/xterm/xterm.min.css">
      <script src="static/xterm/xterm.min.js"></script>
      <script src="static/xterm/addon-fit.min.js"></script>
      #{theme_script()}
      <style>
        html, body { height: 100%; margin: 0; }
        body { display: flex; flex-direction: column; }
        #terminal { flex: 1; padding: 4px 8px; box-sizing: border-box; background: #1e1e1e; }
      </style>
    </head>
    <body>
    #{navbar_html(:iex, user)}
      <div id="terminal"></div>
      <script>
        const term = new Terminal({ cursorBlink: true, fontFamily: "monospace", fontSize: 13, convertEol: true });
        const fit = new FitAddon.FitAddon();
        term.loadAddon(fit);
        term.open(document.getElementById("terminal"));
        fit.fit();
        const proto = location.protocol === "https:" ? "wss://" : "ws://";
        const ws = new WebSocket(proto + location.host + __BASE__ + "/terminal");
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
    archived? = mode == :archived
    title = if archived?, do: "Archived", else: "Flows"

    header_buttons =
      if archived? do
        ""
      else
        ~s|<a href="edit" class="btn btn-sm btn-primary">New flow</a><button id="reload-all" class="btn btn-sm btn-outline-secondary">Reload all</button>|
      end

    """
    #{base_html(title, if(archived?, do: :archived, else: :flows), user)}
      <style>
        /* Header row: distinguish from the flow rows below (uppercase, small,
           muted, subtle bg) so the column labels don't read as a flow. */
        .flows-table thead th {
          text-transform: uppercase;
          font-size: .72rem;
          letter-spacing: .03em;
          font-weight: 600;
          color: var(--bs-secondary-color);
          background: var(--bs-tertiary-bg);
        }
        .status-dot { display: inline-block; width: .7rem; height: .7rem;
          border-radius: 50%; background: var(--bs-secondary-color); vertical-align: middle; }
        .status-dot.is-green { background: var(--bs-success); }
        .status-dot.is-yellow { background: var(--bs-warning); }
        .status-dot.is-red { background: var(--bs-danger); }
        /* broken (won't compile): hollow red ring, distinct from solid red "unloaded" */
        .status-dot.is-broken { background: transparent; border: 2px solid var(--bs-danger); box-sizing: border-box; }
        /* The kebab menu is a Bootstrap .dropdown-menu toggled by our own JS
           (no Bootstrap JS bundle); keep it visible and unclipped by the card. */
        .card { overflow: visible; }
        .dropdown-menu { z-index: 1080; }
      </style>
      <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center">
          <span class="fw-semibold">#{title}</span>
          <div class="d-flex gap-1">#{header_buttons}</div>
        </div>
        <table class="table table-hover align-middle mb-0 flows-table">
          <thead><tr>
            <th class="sortable" data-label="name" data-sort="name" style="cursor:pointer">name</th>
            <th class="sortable" data-label="status" data-sort="loaded" style="cursor:pointer">status</th>
            <th class="sortable" data-label="last triggered" data-sort="last_triggered" style="cursor:pointer">last triggered</th>
            <th class="text-end">actions</th>
          </tr></thead>
          <tbody id="flows"></tbody>
        </table>
      </div>
      <dialog id="error-dlg" class="border rounded-3" style="max-width:640px">
        <h6 class="fw-semibold mb-2">Operation failed</h6>
        <pre class="mb-0" style="white-space:pre-wrap;max-height:400px;overflow:auto"></pre>
        <form method="dialog" class="mt-3 text-end"><button class="btn btn-sm btn-secondary">Close</button></form>
      </dialog>
      <dialog id="confirm-dlg" class="border rounded-3" style="max-width:440px">
        <h6 class="fw-semibold mb-2">Delete flow</h6>
        <p class="mb-0">Delete <span class="dlg-name fw-semibold"></span>? This removes its file and cannot be undone.</p>
        <div class="mt-3 text-end d-flex gap-2">
          <button id="confirm-cancel" class="btn btn-sm btn-secondary">Cancel</button>
          <button id="confirm-ok" class="btn btn-sm btn-danger">Delete</button>
        </div>
      </dialog>
      <dialog id="perm-dlg" class="border rounded-3" style="max-width:360px">
        <h6 class="fw-semibold mb-2">Visibility</h6>
        <p class="small text-secondary mb-2">Who can see and run <span class="perm-name fw-semibold"></span></p>
        <select id="perm-select" class="form-select form-select-sm mb-3"></select>
        <div class="text-end"><button id="perm-close" class="btn btn-sm btn-secondary">Done</button></div>
      </dialog>
      <script>
        #{control_js()}
        const IS_ADMIN = #{is_admin};
        const MODE = "#{if(archived?, do: "archived", else: "flows")}";
        let ALL_USERS = [];
        const errDlg = document.getElementById("error-dlg");
        async function fail(what, r) {
          const e = await r.json().catch(() => ({}));
          errDlg.querySelector("pre").textContent = what + "\\n" + (e.error || r.statusText);
          errDlg.showModal();
        }
        async function act(name, action) {
          const r = await fetch(`api/flows/${name}/${action}`, { method: "POST" });
          if (!r.ok) fail(name + " " + action, r);
          refresh();
        }
        // The clone's name, mirroring the server's rule (<last segment>_clone).
        function cloneName(name) {
          const parts = name.split("/");
          parts[parts.length - 1] += "_clone";
          return parts.join("/");
        }
        // Clone, then open the clone's editor. On failure, show the error and stay.
        async function cloneFlow(f) {
          const r = await fetch(`api/flows/${f.name}/clone`, { method: "POST" });
          if (r.ok) location.href = __BASE__ + "/edit/" + cloneName(f.name);
          else fail(f.name + " clone", r);
        }
        const confirmDlg = document.getElementById("confirm-dlg");
        let confirmName = null;
        function confirmDelete(name) {
          confirmName = name;
          confirmDlg.querySelector(".dlg-name").textContent = name;
          confirmDlg.showModal();
        }
        document.getElementById("confirm-cancel").onclick = () => confirmDlg.close();
        document.getElementById("confirm-ok").onclick = async () => {
          const name = confirmName;
          confirmDlg.close();
          if (name) act(name, "delete");
        };
        async function loadUsers() {
          if (!IS_ADMIN) return;
          try { ALL_USERS = (await (await fetch("api/admin/users")).json()).map((u) => u.name); } catch (_) {}
        }
        async function reloadAll() {
          const r = await fetch("api/flows/reload", { method: "POST" });
          if (!r.ok) fail("reload all", r);
          refresh();
        }
        // Folder tree: flow names may be path-style ("LivingRoom/counter").
        // Expanded folders live in this Set; folders start collapsed.
        const expanded = new Set();
        // Column sorting: sortOrder[0] is primary, [1] the subsort. Clicking a
        // new column makes it primary and demotes the old primary to subsort;
        // clicking the primary toggles asc/desc, and a third click clears the
        // sort back to the default order. The tree is always shown; a sort
        // orders folders and flows together at each level (a folder compares
        // by name, and counts as loaded only if everything inside is loaded).
        const sortOrder = [];
        const sortDir = {};
        function sortBy(key) {
          if (sortOrder[0] === key) {
            if (sortDir[key] === "asc") {
              sortDir[key] = "desc";
            } else {
              sortOrder.length = 0;
            }
          } else if (sortOrder[1] === key) {
            sortOrder[0] = key;
            sortOrder[1] = null;
          } else {
            sortDir[key] = "asc";
            sortOrder[1] = sortOrder[0] || null;
            sortOrder[0] = key;
          }
          refresh();
        }
        function folderAllLoaded(folder) {
          for (const f of folder.flows) if (!f.loaded) return false;
          for (const sub of Object.values(folder.folders)) if (!folderAllLoaded(sub)) return false;
          return true;
        }
        // Sort value of a tree entry (folder or flow) for a column key.
        function entryVal(e, key) {
          if (e.kind === "flow") {
            if (key === "loaded") return e.f.loaded ? 1 : 0;
            if (key === "name") return modLabel(e.f);
            return e.f[key];
          }
          return key === "loaded" ? (folderAllLoaded(e.folder) ? 1 : 0) : e.name;
        }
        function cmpEntries(a, b) {
          for (const key of sortOrder.filter(Boolean)) {
            const va = entryVal(a, key), vb = entryVal(b, key);
            const d = typeof va === "number" ? va - vb : va < vb ? -1 : va > vb ? 1 : 0;
            if (d) return sortDir[key] === "desc" ? -d : d;
          }
          return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
        }
        function updateSortHeaders() {
          for (const th of document.querySelectorAll("th.sortable")) {
            const i = sortOrder.indexOf(th.dataset.sort);
            const arrow = i === 0 ? (sortDir[th.dataset.sort] === "desc" ? " ▼" : " ▲")
              : i === 1 ? (sortDir[th.dataset.sort] === "desc" ? " ↓" : " ↑")
              : "";
            th.textContent = th.dataset.label + arrow;
          }
        }
        function buildTree(flows) {
          const root = { path: "", folders: {}, flows: [] };
          for (const f of flows) {
            const parts = f.name.split("/");
            let node = root;
            for (let i = 0; i < parts.length - 1; i++) {
              const p = parts[i];
              if (!node.folders[p]) node.folders[p] = { path: node.path ? node.path + "/" + p : p, folders: {}, flows: [] };
              node = node.folders[p];
            }
            node.flows.push(f);
          }
          return root;
        }
        function folderCount(node) {
          let n = node.flows.length;
          for (const f of Object.values(node.folders)) n += folderCount(f);
          return n;
        }
        // Detail panel expanded under a flow row: its UI elements + recent logs.
        // Logs survive table re-renders in panel.logs; pushes append live.
        const panel = { name: null, logs: [], sinceId: 0 };
        function logTag(name) { return name.split("/").pop(); }
        function logDiv(line) {
          const d = document.createElement("div");
          d.textContent = line;
          if (line.startsWith("error")) d.className = "text-danger";
          else if (line.startsWith("warning")) d.className = "text-warning-emphasis";
          return d;
        }
        async function togglePanel(name) {
          if (panel.name === name) {
            panel.name = null;
          } else {
            panel.name = name;
            panel.logs = [];
            try {
              const items = await (await fetch("api/logs?since=0")).json();
              for (const it of items) {
                if (it.id > panel.sinceId) panel.sinceId = it.id;
                if (panel.name === name && it.line.includes("[" + logTag(name) + "]")) panel.logs.push(it.line);
              }
              panel.logs = panel.logs.slice(-300);
            } catch (_) {}
          }
          refresh();
        }
        function onLog(msg) {
          if (!panel.name || msg.id <= panel.sinceId) return;
          panel.sinceId = msg.id;
          if (!msg.line.includes("[" + logTag(panel.name) + "]")) return;
          panel.logs.push(msg.line);
          panel.logs = panel.logs.slice(-300);
          const box = document.getElementById("panel-logs");
          if (box) {
            box.appendChild(logDiv(msg.line));
            while (box.children.length > 300) box.removeChild(box.firstChild);
            box.scrollTop = box.scrollHeight;
          }
        }
        function panelRow(f) {
          const tr = document.createElement("tr");
          const td = document.createElement("td");
          td.colSpan = 4;
          td.innerHTML =
            '<div class="d-flex gap-3 p-2 flex-column flex-md-row">' +
            '<div class="border rounded p-2 flex-grow-1"><div class="fw-semibold small mb-2">controls</div>' +
            '<div id="panel-ui" class="d-flex flex-wrap gap-2 align-items-center">loading…</div></div>' +
            '<div class="border rounded p-2 flex-grow-1"><div class="fw-semibold small mb-2">logs</div>' +
            '<div id="panel-logs" style="font-family:ui-monospace,monospace;font-size:12px;white-space:pre-wrap;height:220px;overflow:auto"></div></div>' +
            '</div>';
          tr.appendChild(td);
          const logs = td.querySelector("#panel-logs");
          for (const line of panel.logs) logs.appendChild(logDiv(line));
          logs.scrollTop = logs.scrollHeight;
          fetch(`api/flows/${f.name}/ui`).then((r) => r.json()).then((els) => {
            const box = document.getElementById("panel-ui");
            if (!box) return;
            box.innerHTML = "";
            if (!els.length) {
              box.innerHTML = '<span class="text-secondary small">no ui elements</span>';
              return;
            }
            for (const e of els) box.appendChild(renderControl(e, "btn-sm btn-primary"));
          });
          return tr;
        }
        function timeAgo(ms) {
          if (ms == null) return "never";
          const min = Math.floor((Date.now() - ms) / 60000);
          if (min < 1) return "just now";
          if (min < 60) return min + (min === 1 ? " minute" : " minutes") + " ago";
          const hr = Math.floor(min / 60);
          if (hr < 24) return hr + (hr === 1 ? " hour" : " hours") + " ago";
          const day = Math.floor(hr / 24);
          if (day < 7) return day + (day === 1 ? " day" : " days") + " ago";
          return new Date(ms).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
        }
        function fillOwnerOptions(sel, owner) {
          sel.innerHTML = "";
          const cur = owner === null || owner === undefined ? "" : String(owner);
          const opts = [["public", "All users"], ["", "Admin only"]].concat(ALL_USERS.map((u) => [u, "user: " + u]));
          for (const [val, label] of opts) {
            const o = document.createElement("option");
            o.value = val;
            o.textContent = label;
            if (val === cur) o.selected = true;
            sel.appendChild(o);
          }
        }
        const permDlg = document.getElementById("perm-dlg");
        const permSelect = document.getElementById("perm-select");
        let permName = null;
        function openPerms(f) {
          permName = f.name;
          permDlg.querySelector(".perm-name").textContent = f.name.split("/").pop();
          fillOwnerOptions(permSelect, f.owner);
          permDlg.showModal();
        }
        permSelect.onchange = async () => {
          if (!permName) return;
          const name = permName;
          const r = await fetch(`api/flows/${name}/owner`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ owner: permSelect.value || null }) });
          if (!r.ok) fail(name + " owner", r);
          permDlg.close();
          refresh();
        };
        document.getElementById("perm-close").onclick = () => permDlg.close();
        function closeMenus(except) {
          document.querySelectorAll(".dropdown-menu.show").forEach((m) => { if (m !== except) m.classList.remove("show"); });
        }
        document.addEventListener("click", () => closeMenus());
        // Name shown in the list: the flow's module, trimmed of the
        // Elixir.HomeElixir.Flows. prefix (its leaf). Broken flows (no module)
        // fall back to the file name.
        function modLabel(f) {
          if (f.module) return String(f.module).replace(/^Elixir\.HomeElixir\.Flows\./, "").split(".").pop();
          return f.name.split("/").pop();
        }
        function mkBtn(label, cls) {
          const b = document.createElement("button");
          b.className = "btn btn-sm " + cls;
          b.textContent = label;
          return b;
        }
        function flowRow(f, depth, label) {
          const tr = document.createElement("tr");
          if (MODE !== "archived") {
            tr.style.cursor = "pointer";
            tr.onclick = (ev) => { if (!ev.target.closest("button, a, select, input, .dropdown")) togglePanel(f.name); };
          }
          tr.innerHTML =
            `<td class="fw-semibold" style="padding-left:${12 + depth * 20}px">${modLabel(f)}</td>` +
            `<td><span class="status-dot ${f.status === "grey" ? "" : "is-" + f.status}" title="${f.status}"></span></td>` +
            `<td class="text-secondary">${timeAgo(f.last_triggered)}</td>`;
          const actions = document.createElement("div");
          actions.className = "d-flex gap-2 justify-content-end align-items-center";

          if (MODE === "archived") {
            // Archived: Restore + Delete as direct buttons (no menu, no toggle).
            const restore = mkBtn("Restore", "btn-outline-secondary");
            restore.onclick = () => act(f.name, "unarchive");
            const del = mkBtn("Delete", "btn-outline-danger");
            del.onclick = () => confirmDelete(f.name);
            actions.append(restore, del);
          } else {
            const sw = document.createElement("div");
            sw.className = "form-check form-switch mb-0";
            const cb = document.createElement("input");
            cb.type = "checkbox";
            cb.className = "form-check-input";
            cb.checked = !!f.loaded;
            cb.onchange = () => act(f.name, cb.checked ? "load" : "unload");
            sw.appendChild(cb);
            actions.appendChild(sw);

            const items =
              '<a class="dropdown-item" href="edit/' + f.name + '">Edit</a>' +
              '<button class="dropdown-item" data-a="reload">Reload</button>' +
              (IS_ADMIN ? '<button class="dropdown-item" data-a="perms">Permissions</button>' : "") +
              '<button class="dropdown-item" data-a="clone">Clone</button>' +
              '<button class="dropdown-item" data-a="archive">Archive</button>' +
              '<hr class="dropdown-divider">' +
              '<button class="dropdown-item text-danger" data-a="delete">Delete</button>';

            const dd = document.createElement("div");
            dd.className = "dropdown";
            // data-bs-popper: CSS-only Bootstrap 5 (no JS/Popper) only applies the
            // .dropdown-menu-end alignment (right:0) once Popper marks the element, so
            // without it the menu opens rightward, off-screen, from the far-right trigger.
            dd.innerHTML = '<button class="btn btn-sm btn-outline-secondary" aria-label="menu">⋮</button><div class="dropdown-menu dropdown-menu-end" data-bs-popper>' + items + '</div>';
            actions.appendChild(dd);

            const menuList = dd.querySelector(".dropdown-menu");
            dd.querySelector("button").onclick = (ev) => { ev.stopPropagation(); closeMenus(menuList); menuList.classList.toggle("show"); };
            menuList.querySelectorAll("[data-a]").forEach((el) => {
              el.onclick = () => {
                closeMenus();
                const a = el.dataset.a;
                if (a === "delete") confirmDelete(f.name);
                else if (a === "perms") openPerms(f);
                else if (a === "clone") cloneFlow(f);
                else act(f.name, a);
              };
            });
          }
          tr.appendChild(actions);
          return tr;
        }
        function folderRow(folder, depth) {
          const open = expanded.has(folder.path);
          const tr = document.createElement("tr");
          const td = document.createElement("td");
          td.colSpan = 4;
          td.style.cursor = "pointer";
          td.innerHTML = `<span class="fw-semibold" style="padding-left:${12 + depth * 20}px">${open ? "▾" : "▸"} ${folder.path.split("/").pop()} <span class="text-secondary fw-normal">(${folderCount(folder)})</span></span>`;
          td.onclick = () => { open ? expanded.delete(folder.path) : expanded.add(folder.path); refresh(); };
          tr.appendChild(td);
          return tr;
        }
        function renderNode(node, depth, tbody) {
          const entries = [];
          for (const name of Object.keys(node.folders)) entries.push({ kind: "folder", name, folder: node.folders[name] });
          for (const f of node.flows) entries.push({ kind: "flow", name: modLabel(f), f });
          if (sortOrder.length) {
            entries.sort(cmpEntries);
          } else {
            // Default: folders (alphabetical) first, then flows.
            entries.sort((a, b) => (a.kind === b.kind ? (a.name < b.name ? -1 : 1) : a.kind === "folder" ? -1 : 1));
          }
          for (const e of entries) {
            if (e.kind === "folder") {
              tbody.appendChild(folderRow(e.folder, depth));
              if (expanded.has(e.folder.path)) renderNode(e.folder, depth + 1, tbody);
            } else {
              tbody.appendChild(flowRow(e.f, depth, e.name));
              if (e.f.name === panel.name) tbody.appendChild(panelRow(e.f));
            }
          }
        }
        async function refresh() {
          const all = await (await fetch("api/flows")).json();
          const tbody = document.getElementById("flows");
          if (all && all.busy) {
            tbody.innerHTML = `<tr><td colspan="6" class="text-center text-muted py-4">${all.message || "Loading…"}</td></tr>`;
            return;
          }
          const flows = MODE === "archived" ? all.filter((f) => f.archived) : all.filter((f) => !f.archived);
          tbody.innerHTML = "";
          renderNode(buildTree(flows), 0, tbody);
          updateSortHeaders();
        }
        const reloadAllBtn = document.getElementById("reload-all");
        if (reloadAllBtn) reloadAllBtn.onclick = reloadAll;
        for (const th of document.querySelectorAll("th.sortable")) th.onclick = () => sortBy(th.dataset.sort);
        if (IS_ADMIN) loadUsers().then(refresh);
        else refresh();
        // Push: refresh when the flow set changes elsewhere (editor, IEx, ...).
        connectUI({ flow_changed: refresh, state: updateBadge, log: onLog });
        // Slow safety net for files added or edited on disk without loading.
        setInterval(refresh, 30000);
      </script>
    """
  end

  defp controls_page(user \\ nil) do
    """
    #{base_html("Controls", :controls, user)}
      <div id="controls" class="d-flex flex-column gap-3"></div>
      <script>
        #{control_js()}
        async function refresh() {
          const els = await (await fetch("api/ui")).json();
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

  defp editor_page(name, source, user \\ nil) do
    source_json = Jason.encode!(source)
    name_json = Jason.encode!(name)

    """
    #{base_html("Edit flow", :edit, user)}
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
        .cm-gutter { position: absolute; left: 0; top: 0; bottom: 0; width: 3.4rem;
              overflow: hidden; box-sizing: border-box; z-index: 1;
              background: var(--bs-tertiary-bg); border-right: 1px solid var(--bs-border-color);
              user-select: none; }
        #gutter { padding: 12px 8px 12px 0; font-family: ui-monospace, "SFMono-Regular",
              Menlo, Consolas, monospace; font-size: 13px; line-height: 20px;
              text-align: right; color: var(--bs-secondary-color); white-space: pre; }
        @media (max-width: 768px) { #gutter { font-size: 16px; line-height: 24px; } }
        .cm pre, .cm textarea { left: 3.4rem; }
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
         #cron-overlay { position: fixed; inset: 0; z-index: 1070; display: flex;
               align-items: center; justify-content: center; background: rgba(0, 0, 0, .45); }
         #cron-card { width: min(560px, 94vw); }
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
            <button id="cron-btn" class="btn btn-sm btn-outline-secondary">Cron</button>
            <button id="revert" class="btn btn-sm btn-outline-secondary">Revert</button>
            <button id="save" class="btn btn-sm btn-primary">Save</button>
            <span id="status" class="text-success small"></span>
          </div>
          <div class="cm">
            <div class="cm-gutter"><div id="gutter"></div></div>
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
      <div id="cron-overlay" class="d-none">
        <div id="cron-card" class="card">
          <div class="card-header d-flex align-items-center gap-2">
            <span class="fw-semibold">Cron</span>
            <button id="cron-close" class="btn btn-sm btn-outline-secondary ms-auto" aria-label="Close">×</button>
          </div>
          <div class="card-body">
            <div class="d-flex align-items-center gap-2">
              <input id="cron-in" class="form-control font-monospace" spellcheck="false" style="flex: 1">
              <button id="cron-copy" class="btn btn-sm btn-outline-secondary">Copy</button>
            </div>
            <div id="cron-out" class="mt-2 text-secondary"></div>
            <div id="cron-presets" class="d-flex flex-wrap gap-1 mt-2"></div>
            <div class="text-secondary small mt-2">
              5-field: <code>min hour dom month dow</code> — used by a <code>Schedule</code> node's <code>cron:</code> config.
            </div>
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
      <script src="static/cron/cronstrue.min.js"></script>
      <script>
        #{control_js()}
        const FLOW = #{source_json};
        const FLOWNAME = #{name_json};
        // Log lines are tagged with the flow's short name (last path segment).
        const FLOWLOG = FLOWNAME ? FLOWNAME.split("/").pop() : "";
        const editor = document.getElementById("editor");
        const hl = document.getElementById("hl");
        const pre = document.querySelector(".cm pre");
        const gutter = document.querySelector(".cm-gutter");
        const gutterNums = document.getElementById("gutter");
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
          gutterNums.textContent = editor.value.split("\\n").map((_, i) => i + 1).join("\\n");
          syncScroll();
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
        function syncScroll() {
          pre.scrollTop = editor.scrollTop;
          pre.scrollLeft = editor.scrollLeft;
          gutter.scrollTop = editor.scrollTop;
        }
        editor.addEventListener("scroll", syncScroll);
        render();
        async function doSave() {
          status.textContent = "saving…";
          const headers = FLOWNAME ? { "X-Flow-Name": FLOWNAME } : {};
          const r = await fetch("api/flows/save", { method: "POST", headers, body: editor.value });
          status.textContent = await r.text();
          if (r.ok) savedSource = editor.value;
        }
        async function doRevert() {
          if (!FLOWNAME) { status.textContent = "save first"; return; }
          status.textContent = "reverting…";
          const r = await fetch(`api/flows/${FLOWNAME}/loaded_source`);
          if (!r.ok) { status.textContent = "no loaded state to revert to"; return; }
          const { source } = await r.json();
          editor.value = source;
          render();
          const s = await fetch("api/flows/save", { method: "POST", headers: { "X-Flow-Name": FLOWNAME }, body: editor.value });
          status.textContent = await s.text();
          if (s.ok) savedSource = editor.value;
        }
        async function doCheck() {
          status.textContent = "checking…";
          const r = await fetch("api/flows/check", { method: "POST", body: editor.value });
          status.textContent = await r.text();
        }
        async function doReload() {
          if (!FLOWNAME) { status.textContent = "save first"; return; }
          status.textContent = "reloading…";
          const r = await fetch(`api/flows/${FLOWNAME}/reload`, { method: "POST" });
          const t = await r.text();
          status.textContent = r.ok ? "reloaded" : t;
          refreshControls();
        }
        document.getElementById("save").onclick = doSave;
        document.getElementById("revert").onclick = doRevert;
        document.getElementById("check").onclick = doCheck;
        document.getElementById("reload").onclick = doReload;
        async function refreshControls() {
          if (!FLOWNAME) return;
          const els = await (await fetch(`api/flows/${FLOWNAME}/ui`)).json();
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
            if (msg.line.includes("[" + FLOWLOG + "]")) appendFlowLine(msg.line);
            flowLastId = msg.id;
          }
        }
        async function resyncFlowLogs() {
          flowSyncing = true;
          try {
            const items = await (await fetch("api/logs?since=" + flowLastId)).json();
            for (const it of items) {
              if (it.line.includes("[" + FLOWLOG + "]")) appendFlowLine(it.line);
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

        // ---- cron calculator (cronstrue): humanize / build a Schedule-node cron ----
        const cronOverlay = document.getElementById("cron-overlay");
        const cronIn = document.getElementById("cron-in");
        const cronOut = document.getElementById("cron-out");
        function cronRender() {
          const e = cronIn.value.trim();
          if (!e) { cronOut.textContent = ""; cronOut.className = "mt-2 text-secondary"; return; }
          try { cronOut.textContent = cronstrue.toString(e); cronOut.className = "mt-2"; }
          catch (err) { cronOut.textContent = "Invalid: " + err.message; cronOut.className = "mt-2 text-danger"; }
        }
        function openCron() {
          const m = editor.value.match(/cron:\s*"([^"]+)"/);
          cronIn.value = m ? m[1] : "*/2 * * * *";
          cronOverlay.classList.remove("d-none");
          cronRender(); cronIn.focus(); cronIn.select();
        }
        function closeCron() { cronOverlay.classList.add("d-none"); }
        document.getElementById("cron-btn").onclick = () =>
          cronOverlay.classList.contains("d-none") ? openCron() : closeCron();
        document.getElementById("cron-close").onclick = closeCron;
        cronOverlay.addEventListener("click", (e) => { if (e.target === cronOverlay) closeCron(); });
        document.addEventListener("keydown", (e) => {
          if (e.key === "Escape" && !cronOverlay.classList.contains("d-none")) closeCron();
        });
        cronIn.addEventListener("input", cronRender);
        document.getElementById("cron-copy").onclick = async (e) => {
          try { await navigator.clipboard.writeText(cronIn.value.trim());
            e.target.textContent = "Copied"; setTimeout(() => (e.target.textContent = "Copy"), 1200);
          } catch (_) {}
        };
        for (const [label, val] of [
          ["Every 1 min", "* * * * *"], ["Every 2 min", "*/2 * * * *"], ["Every 5 min", "*/5 * * * *"],
          ["Hourly", "0 * * * *"], ["Daily 9am", "0 9 * * *"], ["Weekdays 9am", "0 9 * * 1-5"],
          ["Monday 3pm", "0 15 * * 1"], ["1st of month", "0 0 1 * *"]
        ]) {
          const b = document.createElement("button");
          b.className = "btn btn-sm btn-outline-secondary";
          b.textContent = label;
          b.onclick = () => { cronIn.value = val; cronRender(); cronIn.focus(); };
          document.getElementById("cron-presets").appendChild(b);
        }
        entSearch.addEventListener("input", renderEnt);
        async function loadEntities() {
          entStatus.textContent = "loading…";
          try { entData = await (await fetch("api/entity_tree")).json(); }
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

  defp logs_page(user \\ nil) do
    """
    #{base_html("Logs", :logs, user)}
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
            const items = await (await fetch("api/logs?since=" + lastId)).json();
            for (const it of items) { appendLine(it.line); lastId = it.id; }
          } catch (e) {}
          syncing = false;
        }
        connectUI({ log: onLog }, resync);
      </script>
    """
  end

  # Standalone (unauthenticated) login page: local username/password or an HA token.
  defp login_page do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="icon" href="static/favicon.ico">
      <title>Log in — home_elixir</title>
      <link href="#{@bootstrap}" rel="stylesheet">
      #{theme_script()}
    </head>
    <body class="p-3 d-flex align-items-center" style="min-height: 100vh">
      <div class="card mx-auto" style="width: min(420px, 94vw)">
        <div class="card-header fw-semibold d-flex align-items-center gap-2"><img src="static/favicon.ico" width="22" height="22" alt="">home_elixir</div>
        <div class="card-body">
          <a href="oauth/start" class="btn btn-primary btn-lg w-100">Log in with Home Assistant</a>
          <div class="text-center text-secondary my-3"><hr class="d-inline-block" style="width:2.2rem">or<hr class="d-inline-block" style="width:2.2rem"></div>
          <details>
            <summary class="text-secondary small">Use username &amp; password</summary>
            <div class="mt-2">
              <div class="mb-2">
                <label class="form-label">Username</label>
                <input id="username" class="form-control" autocomplete="username" spellcheck="false">
              </div>
              <div class="mb-2">
                <label class="form-label">Password</label>
                <input id="password" type="password" class="form-control" autocomplete="current-password">
              </div>
              <button id="login" class="btn btn-outline-secondary w-100">Log in</button>
            </div>
          </details>
          <div id="error" class="text-danger small mt-2"></div>
        </div>
      </div>
      <script>
        function doLogin() {
          const username = document.getElementById("username").value.trim();
          const password = document.getElementById("password").value;
          document.getElementById("error").textContent = "";
          fetch("api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username, password }) })
            .then(async (r) => {
              if (r.ok) { location.href = __BASE__ || "."; }
              else { const e = await r.json().catch(() => ({})); document.getElementById("error").textContent = e.error || "login failed"; }
            })
            .catch(() => (document.getElementById("error").textContent = "network error"));
        }
        document.getElementById("login").onclick = doLogin;
        for (const id of ["username", "password"])
          document.getElementById(id).addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); });
      </script>
    </body>
    </html>
    """
  end

  defp admin_page(user) do
    """
    #{base_html("Admin", :admin, user)}
      <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center flex-wrap gap-2">
          <span class="fw-semibold">Users</span>
          <form id="create" class="d-flex gap-1 align-items-center">
            <input id="new-name" class="form-control form-control-sm" style="width: 9rem" placeholder="username" spellcheck="false">
            <input id="new-pass" class="form-control form-control-sm" style="width: 9rem" placeholder="password" type="text" spellcheck="false">
            <select id="new-role" class="form-select form-select-sm" style="width: 6rem">
              <option value="user">user</option>
              <option value="admin">admin</option>
            </select>
            <button class="btn btn-sm btn-primary">Add user</button>
          </form>
        </div>
        <table class="table table-hover align-middle mb-0">
          <thead><tr><th>name</th><th>role</th><th class="text-end">actions</th></tr></thead>
          <tbody id="users"></tbody>
        </table>
      </div>
      <div class="alert alert-secondary small mt-3">
        "Reset password" works for any user, including your own (no current password needed).
        Deleting a user revokes their live session and blocks that account from logging in again.
      </div>
      <dialog id="reset-dlg" class="border rounded-3" style="max-width:420px">
        <h6 class="fw-semibold mb-2">Reset password</h6>
        <input id="reset-pass" class="form-control form-control-sm mb-2" placeholder="new password" type="text" spellcheck="false">
        <form method="dialog" class="text-end">
          <button id="reset-cancel" class="btn btn-sm btn-secondary">Cancel</button>
          <button id="reset-ok" class="btn btn-sm btn-primary">Save</button>
        </form>
      </dialog>
      <script>
        let resetTarget = null;
        function err(msg) { alert(msg); }
        async function api(url, opts) {
          const r = await fetch(url, opts);
          const j = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(j.error || r.statusText);
          return j;
        }
        async function refresh() {
          const users = await (await fetch("api/admin/users")).json();
          const tbody = document.getElementById("users");
          tbody.innerHTML = "";
          for (const u of users) {
            const tr = document.createElement("tr");
            const tdName = document.createElement("td");
            tdName.className = "fw-semibold";
            tdName.textContent = u.name;
            tr.appendChild(tdName);

            const tdRole = document.createElement("td");
            if (u.name !== "admin") {
              const sel = document.createElement("select");
              sel.className = "form-select form-select-sm";
              for (const r of ["user", "admin"]) {
                const opt = document.createElement("option");
                opt.value = r; opt.textContent = r;
                if (r === u.role) opt.selected = true;
                sel.appendChild(opt);
              }
              sel.onchange = async () => {
                try {
                  await api("api/admin/users/" + u.name + "/role", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ role: sel.value }) });
                  refresh();
                } catch (e) { err(e.message); refresh(); }
              };
              tdRole.appendChild(sel);
            } else {
              tdRole.textContent = "admin";
            }
            tr.appendChild(tdRole);

            const td = document.createElement("td");
            td.className = "text-end";
            const wrap = document.createElement("div");
            wrap.className = "d-flex gap-1 justify-content-end";
            const reset = document.createElement("button");
            reset.className = "btn btn-sm btn-outline-secondary";
            reset.textContent = "Reset password";
            reset.onclick = () => openReset(u.name);
            wrap.appendChild(reset);
            if (u.role !== "admin") {
              const del = document.createElement("button");
              del.className = "btn btn-sm btn-outline-danger";
              del.textContent = "Delete";
              del.onclick = async () => {
                if (!confirm("Delete user " + u.name + "?")) return;
                try { await api("api/admin/users/" + u.name + "/delete", { method: "POST" }); refresh(); }
                catch (e) { err(e.message); }
              };
              wrap.appendChild(del);
            }
            td.appendChild(wrap);
            tr.appendChild(td);
            tbody.appendChild(tr);
          }
        }
        document.getElementById("create").addEventListener("submit", async (e) => {
          e.preventDefault();
          const name = document.getElementById("new-name").value.trim();
          const password = document.getElementById("new-pass").value;
          const role = document.getElementById("new-role").value;
          if (!name || !password) return;
          try {
            await api("api/admin/users", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, password, role }) });
            document.getElementById("new-name").value = "";
            document.getElementById("new-pass").value = "";
            document.getElementById("new-role").value = "user";
            refresh();
          } catch (er) { err(er.message); }
        });
        function openReset(name) {
          resetTarget = name;
          document.getElementById("reset-pass").value = "";
          document.getElementById("reset-dlg").showModal();
        }
        document.getElementById("reset-ok").onclick = async () => {
          const password = document.getElementById("reset-pass").value;
          if (!password) return;
          try {
            await api("api/admin/users/" + resetTarget + "/reset", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password }) });
            document.getElementById("reset-dlg").close();
          } catch (e) { err(e.message); }
        };
        document.getElementById("reset-cancel").onclick = () => document.getElementById("reset-dlg").close();
        refresh();
      </script>
    """
  end

  # Shared control renderer (state badge or clickable button) for the /controls
  # page and the editor's live-controls panel, plus the live-update web socket
  # helpers both pages use.
  defp control_js do
    """
    // Session-lapse guard. If auth is lost while a page is open (cookie expiry,
    // logout in another tab, or an admin deleting/role-changing the account —
    // each drops the live session), the next /api/* call 401s. Send the browser
    // back to /login instead of leaving a blank, half-dead page.
    (function () {
      const real = window.fetch;
      window.fetch = function (input, init) {
        return real(input, init).then((res) => {
          const url = typeof input === "string" ? input : (input && input.url) || "";
          if (res.status === 401 && url.indexOf("api/") === 0 && url.indexOf("api/login") < 0) {
            location.href = __BASE__ ? __BASE__ + "/login" : "login";
          }
          return res;
        });
      };
      // Idle safety net: catch a session that lapses while the page sits open.
      setInterval(() => { window.fetch("api/me"); }, 30000);
    })();
    function setSnapshot(el, value) {
      el.innerHTML = "";
      if (value) {
        const img = document.createElement("img");
        img.src = value; img.className = "img-fluid rounded"; img.style.maxWidth = "220px";
        el.appendChild(img);
      } else {
        const s = document.createElement("span");
        s.className = "text-secondary small"; s.textContent = "no snapshot yet";
        el.appendChild(s);
      }
    }
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
      if (e.type === "image") {
        const wrap = document.createElement("span");
        wrap.className = "d-inline-flex align-items-center";
        wrap.dataset.flow = e.name;
        wrap.dataset.node = e.node;
        wrap.dataset.label = e.label || e.node;
        wrap.dataset.snapshot = "1";
        setSnapshot(wrap, e.value);
        return wrap;
      }
      const b = document.createElement("button");
      b.className = "btn " + (btnClass || "btn-primary");
      b.textContent = e.label || e.node;
      b.onclick = async () => {
        await fetch("api/ui/click", { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name: e.name, node: e.node, payload: e.payload }) });
      };
      return b;
    }
    // Reconnect-with-backoff web socket. `handlers` maps a push `type` to a fn(msg).
    function connectUI(handlers, onOpen, retryMs) {
      const proto = location.protocol === "https:" ? "wss://" : "ws://";
      const ws = new WebSocket(proto + location.host + __BASE__ + "/api/ui/ws");
      if (onOpen) ws.onopen = () => onOpen();
      ws.onmessage = (e) => {
        try { const m = JSON.parse(e.data); if (handlers[m.type]) handlers[m.type](m); } catch (_) {}
      };
      ws.onclose = () => setTimeout(() => connectUI(handlers, onOpen, retryMs), retryMs || 2000);
      return ws;
    }
    // Update one badge from a pushed {flow, node, value} update. Pushes carry
    // the flow's short name, so also match the last segment of path-style names.
    function updateBadge(u) {
      const el = [...document.querySelectorAll('[data-node="' + u.node + '"]')].find(
        (b) => b.dataset.flow === u.flow || b.dataset.flow.split("/").pop() === u.flow);
      if (!el) return;
      if (el.dataset.snapshot) { setSnapshot(el, u.value); return; }
      el.textContent = el.dataset.label + ": " + (u.value === null || u.value === undefined ? "-" : u.value);
    }
    """
  end

  defp base_html(title, active, user \\ nil) do
    nav = navbar_html(active, user)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="icon" href="static/favicon.ico">
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

  # Shared top navbar (all pages) + the light/dark toggle + the logged-in user's
  # name/role and Log out. Logs, IEx and the Admin page are shown to admins only.
  defp navbar_html(active, user \\ nil) do
    a = fn key -> if key == active, do: " active", else: "" end
    admin? = user != nil and elem(user, 1) == "admin"

    """
    <nav class="navbar navbar-expand-lg bg-body-tertiary rounded-3 mb-3 px-3">
      <div class="container-fluid">
        <a class="navbar-brand fw-semibold d-flex align-items-center gap-2" href="./"><img src="static/favicon.ico" width="24" height="24" alt="">home_elixir</a>
        <ul class="navbar-nav gap-1 flex-wrap">
          <li class="nav-item"><a class="nav-link#{a.(:flows)}" href="./">Flows</a></li>
          <li class="nav-item"><a class="nav-link#{a.(:archived)}" href="archived">Archived</a></li>
          <li class="nav-item"><a class="nav-link#{a.(:controls)}" href="controls">Controls</a></li>
          #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:logs)}" href="logs">Logs</a></li>|, else: ""}
          #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:iex)}" href="terminal">IEx</a></li>|, else: ""}
          #{if admin?, do: ~s|<li class="nav-item"><a class="nav-link#{a.(:admin)}" href="admin">Admin</a></li>|, else: ""}
        </ul>
        #{user_menu_html(user)}
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

    """
    <span class="navbar-text ms-auto me-2 d-flex align-items-center">
      #{name}#{badge}
      <button id="logout" class="btn btn-outline-secondary btn-sm ms-2">Log out</button>
    </span>
    """
  end
end
