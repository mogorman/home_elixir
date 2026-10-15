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

    if public?(conn) do
      HomeElixir.Web.call(conn, inner)
    else
      case HomeElixir.Auth.user_from_conn(conn) do
        {:ok, user} -> HomeElixir.Web.call(conn |> assign(:user, user), inner)
        _ -> reject(conn)
      end
    end
  end

  defp public?(conn) do
    p = conn.request_path
    p in @public_paths or String.starts_with?(p, "/static/")
  end

  defp reject(%{request_path: path} = conn) do
    if String.starts_with?(path, "/api/") do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s|{"error":"unauthorized"}|)
    else
      conn
      |> put_resp_header("location", "/login")
      |> send_resp(302, "")
    end
  end
end
