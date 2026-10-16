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
    # Relative static URLs from the editor page resolve as /edit/static/...
    if String.contains?(name, "/static/") do
      rest = :binary.split(name, "/static/", [global: false]) |> Enum.at(1)
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

  def dispatch(%{method: "GET"} = conn, _opts), do: handle_get(conn)

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

  defp handle_get(conn), do: not_found(conn)

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
    Template.render("terminal.html.eex",
      bootstrap: @bootstrap,
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
    archived? = mode == :archived
    title = if archived?, do: "Archived", else: "Flows"

    header_buttons =
      if archived? do
        ""
      else
        ~s|<a href="edit" class="btn btn-sm btn-primary">New flow</a><button id="reload-all" class="btn btn-sm btn-outline-secondary">Reload all</button>|
      end

    Template.render("list.html.eex",
      base: base_html(title, if(archived?, do: :archived, else: :flows), user),
      title: title,
      header_buttons: header_buttons,
      is_admin: is_admin,
      mode_string: if(archived?, do: "archived", else: "flows"),
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

  defp login_page do
    Template.render("login.html.eex",
      bootstrap: @bootstrap,
      theme_script: Template.render("theme_script.html.eex")
    )
  end

  defp admin_page(user) do
    Template.render("admin.html.eex",
      base: base_html("Admin", :admin, user)
    )
  end

  defp base_html(title, active, user \\ nil) do
    Template.render("base.html.eex",
      title: title,
      bootstrap: @bootstrap,
      theme_script: Template.render("theme_script.html.eex"),
      nav: navbar_html(active, user)
    )
  end

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
