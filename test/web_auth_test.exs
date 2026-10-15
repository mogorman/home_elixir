defmodule HomeElixir.WebAuthTest do
  use ExUnit.Case, async: false

  alias HomeElixir.{Auth, AuthGuard, FlowState}

  # The app (booted by `mix test`) runs Auth, FlowStore, and Registry. The web
  # server itself is off in :test, so we drive HomeElixir.AuthGuard directly with
  # Plug test conns — the same code path Cowboy would use.

  setup do
    FlowState.start()

    tmp = Path.join(System.tmp_dir!(), "web_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "alpha.ex"), "defmodule HomeElixir.Flows.WAAlpha do end")
    File.write!(Path.join(tmp, "beta.ex"), "defmodule HomeElixir.Flows.WABeta do end")
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  # Run a conn through the guard and return the sent response as a map.
  defp run(conn) do
    {status, headers, body} = Plug.Test.sent_resp(AuthGuard.call(conn, AuthGuard.init([])))
    %{status: status, headers: headers, body: body}
  end

  defp get(path, token \\ nil) do
    conn = Plug.Test.conn(:get, path)
    conn = if token, do: Plug.Conn.put_req_header(conn, "cookie", "he_session=" <> token), else: conn
    run(conn)
  end

  defp post(path, body, token) do
    conn = Plug.Test.conn(:post, path, body)
    conn = if token, do: Plug.Conn.put_req_header(conn, "cookie", "he_session=" <> token), else: conn
    run(conn)
  end

  defp header(result, name) do
    Enum.find_value(result.headers, fn {k, v} -> if k == name, do: v end)
  end

  defp session_cookie(user, role), do: Auth.create_session(user, role)

  test "unauthenticated requests are blocked" do
    home = get("/")
    assert home.status == 302
    assert header(home, "location") == "/login"

    api = get("/api/flows")
    assert api.status == 401
  end

  test "login sets a session cookie and /api/me returns the user" do
    result = post("/api/login", Jason.encode!(%{username: "admin", password: "admin-pass"}), nil)
    assert result.status == 302
    assert header(result, "location") == "/"
    set_cookie = header(result, "set-cookie")
    assert set_cookie =~ "he_session="

    token = set_cookie |> String.split(";") |> hd() |> String.replace_prefix("he_session=", "")
    me = get("/api/me", token)
    assert me.status == 200
    assert Jason.decode!(me.body) == %{"name" => "admin", "role" => "admin"}
  end

  test "login rejects bad credentials" do
    result = post("/api/login", Jason.encode!(%{username: "admin", password: "nope"}), nil)
    assert result.status == 401
    assert Jason.decode!(result.body)["error"] =~ "invalid"
  end

  test "a user only sees their own flows; admin sees all" do
    FlowState.set_flow_owner("alpha", "alice")
    FlowState.set_flow_owner("beta", "bob")

    alice = get("/api/flows", session_cookie("alice", "user"))
    alice_names = alice.body |> Jason.decode!() |> Enum.map(& &1["name"])
    assert alice_names == ["alpha"]

    admin = get("/api/flows", session_cookie("admin", "admin"))
    admin_names = admin.body |> Jason.decode!() |> Enum.map(& &1["name"]) |> Enum.sort()
    assert admin_names == ["alpha", "beta"]
  end

  test "a public flow is visible to and accessible by non-admin users" do
    FlowState.set_flow_owner("alpha", "public")
    FlowState.set_flow_owner("beta", "bob")

    alice = session_cookie("alice", "user")

    # alice sees the public flow (alpha) in her list, not bob's (beta).
    names = get("/api/flows", alice).body |> Jason.decode!() |> Enum.map(& &1["name"])
    assert "alpha" in names
    refute "beta" in names

    # alice can open the public flow's editor but not bob's.
    assert get("/edit/alpha", alice).status == 200
    assert get("/edit/beta", alice).status == 403
  end

  test "non-admin is forbidden from /logs, /terminal, and /admin; admin can open them" do
    token = session_cookie("alice", "user")
    for path <- ["/logs", "/terminal", "/admin"] do
      assert get(path, token).status == 403
    end

    admin = session_cookie("admin", "admin")
    for path <- ["/logs", "/admin"] do
      assert get(path, admin).status == 200
    end
  end

  test "non-admin cannot load another user's flow" do
    FlowState.set_flow_owner("alpha", "bob")

    result = post("/api/flows/alpha/load", "", session_cookie("alice", "user"))
    assert result.status == 400
    assert Jason.decode!(result.body)["error"] == "forbidden"
  end

  # ---- OAuth routes (public) ----

  defp with_ha_env(fun) do
    prev_ha = Application.get_env(:home_elixir, :ha_url)
    prev_base = Application.get_env(:home_elixir, :web_base_url)
    Application.put_env(:home_elixir, :ha_url, "wss://ha.test:8123/api/websocket")
    Application.put_env(:home_elixir, :web_base_url, "http://127.0.0.1:4000")

    try do
      fun.()
    after
      Application.put_env(:home_elixir, :ha_url, prev_ha)
      Application.put_env(:home_elixir, :web_base_url, prev_base)
    end
  end

  test "GET /oauth/start redirects to the HA authorize page" do
    with_ha_env(fn ->
      r = get("/oauth/start")
      assert r.status == 302
      assert header(r, "location") =~ "/auth/authorize"
      assert header(r, "location") =~ "code_challenge_method=S256"
    end)
  end

  test "GET /oauth/callback without a code bounces to /login" do
    with_ha_env(fn ->
      assert get("/oauth/callback").status == 302
      assert get("/oauth/callback") |> header("location") == "/login"
      assert get("/oauth/callback?error=denied") |> header("location") == "/login"
    end)
  end
end
