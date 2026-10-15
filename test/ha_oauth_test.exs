defmodule HomeElixir.HA.OAuthTest do
  use ExUnit.Case, async: false

  alias HomeElixir.HA
  alias HomeElixir.HA.OAuth

  setup do
    prev_ha = Application.get_env(:home_elixir, :ha_url)
    prev_base = Application.get_env(:home_elixir, :web_base_url)
    Application.put_env(:home_elixir, :ha_url, "wss://ha.test:8123/api/websocket")
    Application.put_env(:home_elixir, :web_base_url, "http://127.0.0.1:4000")

    on_exit(fn ->
      Application.put_env(:home_elixir, :ha_url, prev_ha)
      Application.put_env(:home_elixir, :web_base_url, prev_base)
    end)

    :ok
  end

  test "start_login builds an authorize URL with a valid state + PKCE pair" do
    assert {:ok, url, state} = OAuth.start_login()

    q = url |> URI.parse() |> then(&URI.decode_query(&1.query))
    assert q["state"] == state
    assert q["response_type"] == "code"
    assert q["client_id"] == "http://127.0.0.1:4000"
    assert q["redirect_uri"] == "http://127.0.0.1:4000/oauth/callback"
    assert q["code_challenge_method"] == "S256"

    # The stored code_verifier must hash to the challenge in the URL (S256).
    verifier = HomeElixir.HA.PendingLogins.get(state)
    assert is_binary(verifier)

    challenge =
      :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert q["code_challenge"] == challenge
    assert url =~ "/auth/authorize"
  end

  test "complete_login rejects an unknown state" do
    assert {:error, :invalid_state} = OAuth.complete_login("code", "not-a-real-state")
  end

  test "complete_login exchanges the code for a token (state consumed once)" do
    Application.put_env(:oauth2, :adapter, Tesla.Mock)

    Tesla.Mock.mock_global(fn env ->
      assert env.method == :post
      assert env.url =~ "/auth/token"
      assert env.body =~ "code=code123"
      assert env.body =~ "code_verifier="
      assert env.body =~ "grant_type=authorization_code"

      {:ok, Tesla.Mock.json(%{"access_token" => "tok123", "token_type" => "bearer"})}
    end)

    # Cleanup must run in the test process (the mock's supervised agent is not
    # reachable from the on_exit runner).
    try do
      assert {:ok, _url, state} = OAuth.start_login()
      assert {:ok, "tok123"} = OAuth.complete_login("code123", state)

      # The state is single-use.
      assert {:error, :invalid_state} = OAuth.complete_login("code123", state)
    after
      # No reset API in this Tesla version; the adapter switch below makes the
      # mock inert, and a flunk catches any stray call in this test process.
      Tesla.Mock.mock_global(fn _env -> flunk("unexpected Tesla request after teardown") end)
      Application.put_env(:oauth2, :adapter, Tesla.Adapter.Httpc)
    end
  end

  test "whoami errors when HA is not configured" do
    prev = Application.get_env(:home_elixir, :ha_url)
    Application.put_env(:home_elixir, :ha_url, nil)

    try do
      assert {:error, _} = HA.whoami("tok")
    after
      Application.put_env(:home_elixir, :ha_url, prev)
    end
  end
end
