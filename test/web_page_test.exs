defmodule HomeElixir.WebPageTest do
  use ExUnit.Case, async: false

  alias HomeElixir.{Auth, AuthGuard, FlowState}

  # A flow may serve its own web page: `web_page("/path")` routes GET /path to the
  # flow's `page_html/0` EEx template. Auth is required by default; `public: true`
  # opts out. We drive AuthGuard directly with Plug test conns (server is off in
  # :test), matching the code path Cowboy would use.

  setup do
    FlowState.start()

    tmp = Path.join(System.tmp_dir!(), "web_page_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(Path.join(tmp, "wp_auth.ex"), """
    defmodule HomeElixir.Flows.WPAuth do
      use HomeElixir.Flow

      web_page("/wp_auth")

      def page_data, do: %{greeting: "hello-flow"}

      def page_html, do: "<html><head></head><body>HELLO=<%= greeting %></body></html>"
    end
    """)

    File.write!(Path.join(tmp, "wp_pub.ex"), """
    defmodule HomeElixir.Flows.WPPub do
      use HomeElixir.Flow

      web_page("/wp_pub", public: true)

      def page_html, do: "<html><head></head><body>PUBLIC-PAGE</body></html>"
    end
    """)

    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp run(conn) do
    {status, headers, body} = Plug.Test.sent_resp(AuthGuard.call(conn, AuthGuard.init([])))
    %{status: status, headers: headers, body: body}
  end

  defp get(path, token \\ nil) do
    conn = Plug.Test.conn(:get, path)
    conn = if token, do: Plug.Conn.put_req_header(conn, "cookie", "he_session=" <> token), else: conn
    run(conn)
  end

  defp session_cookie(user, role), do: Auth.create_session(user, role)

  test "a flow page requires auth by default and renders the flow's data when authed" do
    assert get("/wp_auth").status == 302

    authed = get("/wp_auth", session_cookie("admin", "admin"))
    assert authed.status == 200
    assert authed.body =~ "HELLO=hello-flow"
  end

  test "a flow page can be public and renders without auth" do
    result = get("/wp_pub")
    assert result.status == 200
    assert result.body =~ "PUBLIC-PAGE"
  end

  test "unknown paths still 404" do
    assert get("/wp_nope", session_cookie("admin", "admin")).status == 404
  end
end
