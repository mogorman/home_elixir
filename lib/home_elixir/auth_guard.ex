defmodule HomeElixir.AuthGuard do
  @moduledoc """
  Wraps `HomeElixir.Web` and enforces a session on every route except the public
  ones (`/login`, `/api/login`, static assets, favicon). On success it assigns
  `conn.assigns.user = {username, role}` and hands the conn to `HomeElixir.Web`;
  on failure it redirects HTML requests to `/login` and answers `/api/*` with 401.
  """
  @behaviour Plug
  import Plug.Conn

  @public_paths ["/login", "/api/login", "/api/logout", "/oauth/start", "/oauth/callback", "/favicon.ico"]

  def init(opts), do: opts

  def call(conn, opts) do
    conn = Plug.Conn.fetch_cookies(conn)
    inner = HomeElixir.Web.init(opts)

    # The app may be served under an ingress/proxy prefix (/api/ingress/<uuid>/).
    # Judge public-ness and the 401-vs-login choice on the prefix-less path; the
    # prefix is only re-added to the login redirect. Web re-detects + strips it
    # when it renders.
    base = HomeElixir.Web.base_path(conn.request_path)
    rel = if base == "", do: conn.request_path, else: String.replace_prefix(conn.request_path, base, "")

    if public?(rel) do
      HomeElixir.Web.call(conn, inner)
    else
      case HomeElixir.Auth.user_from_conn(conn) do
        {:ok, user} -> HomeElixir.Web.call(conn |> assign(:user, user), inner)
        _ -> reject(conn, base, rel)
      end
    end
  end

  defp public?(p) do
    p in @public_paths or String.starts_with?(p, "/static/")
  end

  defp reject(conn, base, rel) do
    if String.starts_with?(rel, "/api/") do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s|{"error":"unauthorized"}|)
    else
      # Behind HA ingress the supervisor strips the /api/ingress/<uuid> prefix,
      # so an absolute /login redirect escapes to the HA root. Use a relative
      # redirect so the browser stays within the ingress path.
      location =
        if ingress?(conn) do
          "login"
        else
          base <> "/login"
        end

      conn
      |> put_resp_header("location", location)
      |> send_resp(302, "")
    end
  end

  defp ingress?(conn), do: get_req_header(conn, "x-ingress") != []
end
