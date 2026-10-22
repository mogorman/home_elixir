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
      FlowState.forget_flow("alpha")
      FlowState.forget_flow("beta")
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

    conn =
      if token, do: Plug.Conn.put_req_header(conn, "cookie", "he_session=" <> token), else: conn

    run(conn)
  end

  defp post(path, body, token, headers \\ []) do
    conn = Plug.Test.conn(:post, path, body)

    conn =
      if token, do: Plug.Conn.put_req_header(conn, "cookie", "he_session=" <> token), else: conn

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

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

  test "GET /archived renders for a logged-in user" do
    assert get("/archived", session_cookie("admin", "admin")).status == 200
  end

  test "archive / unarchive respect ownership" do
    FlowState.set_flow_owner("alpha", "bob")

    # owner can archive; the flow is flagged
    assert post("/api/flows/alpha/archive", "", session_cookie("bob", "user")).status == 200
    assert FlowState.is_archived?("alpha")

    # non-owner is forbidden
    r = post("/api/flows/alpha/archive", "", session_cookie("alice", "user"))
    assert r.status == 400
    assert Jason.decode!(r.body)["error"] == "forbidden"

    # owner can unarchive
    assert post("/api/flows/alpha/unarchive", "", session_cookie("bob", "user")).status == 200
    refute FlowState.is_archived?("alpha")
  end

  test "delete removes the flow file; non-owner is forbidden" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    FlowState.set_flow_owner("beta", "bob")
    assert File.exists?(Path.join(tmp, "beta.ex"))

    r = post("/api/flows/beta/delete", "", session_cookie("alice", "user"))
    assert r.status == 400
    assert Jason.decode!(r.body)["error"] == "forbidden"

    assert post("/api/flows/beta/delete", "", session_cookie("bob", "user")).status == 200
    refute File.exists?(Path.join(tmp, "beta.ex"))
  end

  # ---- download / import flow files ----

  test "download returns the flow source as an attachment" do
    src = File.read!(Path.join(Application.get_env(:home_elixir, :flows_dir), "alpha.ex"))
    r = get("/api/flows/alpha/download", session_cookie("admin", "admin"))
    assert r.status == 200
    assert header(r, "content-disposition") =~ ~s|filename="alpha.ex"|
    assert r.body == src
  end

  test "download is forbidden for a flow you don't own" do
    FlowState.set_flow_owner("alpha", "bob")
    r = get("/api/flows/alpha/download", session_cookie("alice", "user"))
    assert r.status == 403
  end

  test "download-all returns a JSON map of the visible flows" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    r = get("/api/flows/download-all?format=json", session_cookie("admin", "admin"))
    assert r.status == 200
    assert header(r, "content-disposition") =~ "home-elixir-flows.json"
    assert header(r, "content-type") =~ "application/json"

    bundle = Jason.decode!(r.body)
    assert Map.get(bundle, "alpha") == File.read!(Path.join(tmp, "alpha.ex"))
    assert Map.get(bundle, "beta") == File.read!(Path.join(tmp, "beta.ex"))
  end

  test "download-all as tar returns a round-trippable tarball" do
    if HomeElixir.Bundle.available?(:tar) do
      r = get("/api/flows/download-all?format=tar", session_cookie("admin", "admin"))
      assert r.status == 200
      assert header(r, "content-type") =~ "application/x-tar"

      assert {:ok, pairs} = HomeElixir.Bundle.consume(r.body, :tar)
      assert Map.has_key?(Map.new(pairs), "alpha")
    end
  end

  test "import a JSON bundle creates new flows" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    on_exit(fn -> FlowState.forget_flow("wa_new") end)

    bundle = Jason.encode!(%{"wa_new" => "defmodule HomeElixir.Flows.WANew do\n  use HomeElixir.Flow\nend\n"})
    r = post("/api/flows/import", bundle, session_cookie("admin", "admin"), [{"x-bundle-format", "json"}])
    assert r.status == 200

    body = Jason.decode!(r.body)
    assert body["created"] == 1
    assert body["updated"] == 0
    assert body["ok"] == true
    assert File.exists?(Path.join(tmp, "wa_new.ex"))
  end

  test "import updates an owned flow, skips a foreign flow and a no-module entry" do
    tmp = Application.get_env(:home_elixir, :flows_dir)
    FlowState.set_flow_owner("alpha", "bob")
    on_exit(fn -> FlowState.forget_flow("wa_new2") end)

    bundle =
      Jason.encode!(%{
        "alpha" => "defmodule HomeElixir.Flows.Alpha do\nend\n",
        "wa_new2" => "defmodule HomeElixir.Flows.WANew2 do\nend\n",
        "junk" => "just some text, no module"
      })

    r = post("/api/flows/import", bundle, session_cookie("alice", "user"), [{"x-bundle-format", "json"}])
    assert r.status == 200

    body = Jason.decode!(r.body)
    assert body["created"] == 1
    assert body["updated"] == 0
    assert length(body["skipped"]) == 2
    assert "alpha" in Enum.map(body["skipped"], & &1["name"])
    assert File.exists?(Path.join(tmp, "wa_new2.ex"))
  end

  test "import rejects a non-JSON body and a missing format header" do
    r = post("/api/flows/import", "not json", session_cookie("admin", "admin"), [{"x-bundle-format", "json"}])
    assert r.status == 400

    r2 = post("/api/flows/import", "anything", session_cookie("admin", "admin"))
    assert r2.status == 400
  end

  test "import a tar bundle creates new flows" do
    if HomeElixir.Bundle.available?(:tar) do
      tmp = Application.get_env(:home_elixir, :flows_dir)
      on_exit(fn -> FlowState.forget_flow("wa_tarn") end)

      assert {:ok, {bytes, _fn, _ct}} =
               HomeElixir.Bundle.produce([{"wa_tarn", "defmodule HomeElixir.Flows.WATarn do\n  use HomeElixir.Flow\nend\n"}], :tar)

      r = post("/api/flows/import", bytes, session_cookie("admin", "admin"), [{"x-bundle-format", "tar"}])
      assert r.status == 200
      assert Jason.decode!(r.body)["created"] == 1
      assert File.exists?(Path.join(tmp, "wa_tarn.ex"))
    end
  end

  test "import and download-all round-trip as zip" do
    if HomeElixir.Bundle.available?(:zip) do
      tmp = Application.get_env(:home_elixir, :flows_dir)
      on_exit(fn -> FlowState.forget_flow("wa_zipn") end)

      src = "defmodule HomeElixir.Flows.WAZipn do\n  use HomeElixir.Flow\nend\n"
      assert {:ok, {bytes, _fn, _ct}} = HomeElixir.Bundle.produce([{"wa_zipn", src}], :zip)

      r = post("/api/flows/import", bytes, session_cookie("admin", "admin"), [{"x-bundle-format", "zip"}])
      assert r.status == 200
      assert Jason.decode!(r.body)["created"] == 1

      got = get("/api/flows/download-all?format=zip", session_cookie("admin", "admin"))
      assert got.status == 200
      assert {:ok, pairs} = HomeElixir.Bundle.consume(got.body, :zip)
      assert Map.get(Map.new(pairs), "wa_zipn") == File.read!(Path.join(tmp, "wa_zipn.ex"))
    end
  end

  test "backup download is admin-only and returns a state doc" do
    r = get("/api/backup", session_cookie("admin", "admin"))
    assert r.status == 200
    assert header(r, "content-type") =~ "application/json"

    doc = Jason.decode!(r.body)
    assert doc["home_elixir_backup"] == 1
    assert is_map(doc["flows"])
    assert is_list(doc["users"])

    assert get("/api/backup", session_cookie("alice", "user")).status == 403
  end

  test "restore is admin-only and applies a backup doc" do
    doc = Jason.encode!(HomeElixir.Backup.snapshot())

    r = post("/api/restore", doc, session_cookie("admin", "admin"))
    assert r.status == 200
    assert Jason.decode!(r.body)["ok"] == true

    assert post("/api/restore", doc, session_cookie("alice", "user")).status == 403
    assert post("/api/restore", "not json", session_cookie("admin", "admin")).status == 400
  end

  # ---- ingress / proxy base path (/api/ingress/<uuid>/) ----

  test "unauthenticated ingress panel root redirects to the prefixed login" do
    r = get("/api/ingress/abc123/")
    assert r.status == 302
    assert header(r, "location") == "/api/ingress/abc123/login"
  end

  test "unauthenticated ingress api path 401s (not a login redirect)" do
    assert get("/api/ingress/abc123/api/flows").status == 401
  end

  test "authenticated ingress panel renders with the base href + const" do
    r = get("/api/ingress/abc123/", session_cookie("admin", "admin"))
    assert r.status == 200
    assert r.body =~ ~s|<base href="/api/ingress/abc123/">|
    assert r.body =~ ~s|window.__BASE__ = "/api/ingress/abc123"|
  end

  test "authenticated ingress api routes on the prefix-less path" do
    r = get("/api/ingress/abc123/api/me", session_cookie("admin", "admin"))
    assert r.status == 200
    assert Jason.decode!(r.body) == %{"name" => "admin", "role" => "admin"}
  end

  test "direct (no prefix) requests still get a root base href" do
    r = get("/", session_cookie("admin", "admin"))
    assert r.status == 200
    assert r.body =~ ~s|<base href="/">|
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
