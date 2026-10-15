defmodule HomeElixir.AuthTest do
  use ExUnit.Case, async: false

  alias HomeElixir.Auth

  setup_all do
    # The app (booted by `mix test`) already started Auth, seeded with the
    # fixed test admin from config/config.exs ("admin" / "admin-pass").
    # FlowState.start/0 is idempotent and guarantees Mnesia is up.
    HomeElixir.FlowState.start()
    :ok
  end

  test "seeds the configured admin" do
    assert {:ok, {"admin", "admin"}} = Auth.login("admin", "admin-pass")
    assert {:error, :bad_credentials} = Auth.login("admin", "wrong")
    assert {:error, :bad_credentials} = Auth.login("nobody", "x")
  end

  test "create / list / delete user" do
    assert :ok = Auth.create_user("alice", "pw-alice")
    assert {:ok, {"alice", "user"}} = Auth.login("alice", "pw-alice")

    names = Auth.list_users() |> Enum.map(& &1.name)
    assert "admin" in names and "alice" in names

    assert {:error, :exists} = Auth.create_user("alice", "again")

    assert :ok = Auth.delete_user("alice")
    assert {:error, :bad_credentials} = Auth.login("alice", "pw-alice")
  end

  test "the reserved 'public' username cannot be created" do
    assert {:error, _} = Auth.create_user("public", "pw")
    assert {:error, :bad_credentials} = Auth.login("public", "pw")
  end

  test "admin account cannot be deleted" do
    assert {:error, _} = Auth.delete_user("admin")
    assert {:ok, {"admin", "admin"}} = Auth.login("admin", "admin-pass")
  end

  test "reset password (admin) and change password (self, needs old)" do
    :ok = Auth.create_user("bob", "old")

    # Self-change with wrong old password fails, correct one succeeds.
    assert {:error, :bad_password} = Auth.change_password("bob", "nope", "new")
    assert :ok = Auth.change_password("bob", "old", "mid")
    assert {:ok, {"bob", "user"}} = Auth.login("bob", "mid")

    # Admin reset does not need the old password.
    assert :ok = Auth.reset_password("bob", "reset")
    assert {:ok, {"bob", "user"}} = Auth.login("bob", "reset")

    # Reset on a missing user fails.
    assert {:error, :not_found} = Auth.reset_password("ghost", "x")
  end

  test "set_role changes a user's level; protects the built-in admin" do
    :ok = Auth.create_user("dave", "pw")
    assert {:ok, {"dave", "user"}} = Auth.login("dave", "pw")

    assert :ok = Auth.set_role("dave", "admin")
    assert {:ok, {"dave", "admin"}} = Auth.login("dave", "pw")

    assert :ok = Auth.set_role("dave", "user")
    assert {:ok, {"dave", "user"}} = Auth.login("dave", "pw")

    # Invalid role, the built-in admin, and a missing user are all rejected.
    assert {:error, :bad_role} = Auth.set_role("dave", "superuser")
    assert {:error, _} = Auth.set_role("admin", "user")
    assert {:error, :not_found} = Auth.set_role("ghost", "admin")

    :ok = Auth.delete_user("dave")
  end

  test "sessions: create, resolve, expire, delete" do
    token = Auth.create_session("alice", "user")
    assert {:ok, {"alice", "user"}} = Auth.resolve_session(token)

    # Unknown / empty tokens are rejected.
    assert {:error, :unauthorized} = Auth.resolve_session("bogus")
    assert {:error, :unauthorized} = Auth.resolve_session(nil)

    # Deleting the token invalidates it.
    :ok = Auth.delete_session(token)
    assert {:error, :unauthorized} = Auth.resolve_session(token)

    # Deleting a user drops their live sessions.
    :ok = Auth.create_user("carol", "pw")
    t2 = Auth.create_session("carol", "user")
    assert {:ok, _} = Auth.resolve_session(t2)
    :ok = Auth.delete_user("carol")
    assert {:error, :unauthorized} = Auth.resolve_session(t2)
  end

  test "HA token login returns an error for an unusable token" do
    # Point at a dead local port so no real HA is hit (wins when the host has no
    # HA_URL env; if one is set, the bogus token is still rejected). Either way
    # the result is an error.
    prev = Application.get_env(:home_elixir, :ha_url)

    try do
      Application.put_env(:home_elixir, :ha_url, "http://127.0.0.1:1")
      assert {:error, _} = Auth.login_ha_token("bogus-token")
    after
      Application.put_env(:home_elixir, :ha_url, prev)
    end
  end

  test "HA identity: reserved name rejected, normal names mapped" do
    assert {:error, :reserved_name} = Auth.ha_identity("public", false)
    assert {:ok, {"alice", "admin"}} = Auth.ha_identity("alice", true)
    assert {:ok, {"bob", "user"}} = Auth.ha_identity("bob", false)
  end
end
