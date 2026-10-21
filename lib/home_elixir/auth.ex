defmodule HomeElixir.Auth do
  @moduledoc """
  Local accounts (Mnesia), in-memory sessions (ETS), and PBKDF2 password
  hashing via OTP `:crypto` — no external deps, so the hermetic Nix build is
  untouched.

  On start it seeds accounts from `:home_elixir, :auth_users` (username =>
  password) and always ensures an `admin`: its password from that config, or a
  freshly generated one (printed to the log) when none is configured.

  A user logs in with a local password (`login/2`) or a Home Assistant token
  (`login_ha_token/1`), whose identity and role are resolved via HA's WebSocket
  `auth/current_user` (`is_admin` maps to the local `admin` role).
  """
  use GenServer
  require Logger

  @salt_bytes 16
  @iterations 210_000
  @key :sha256
  @table :home_elixir_users
  @sessions :he_sessions
  @cookie "he_session"
  @admin "admin"

  # A user record: {table, id, salt, hash, role}, with `id` (the username) as the
  # key — the same "table name as record head" shape HomeElixir.FlowState uses.
  defp rec(id, salt, hash, role), do: {@table, id, salt, hash, role}

  # ---- lifecycle ----

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Mnesia is already started by HomeElixir.FlowState.start() at app boot (and
    # in tests). start/0 is idempotent, so a bare call here is safe.
    :mnesia.start()
    ensure_table()
    ensure_sessions()
    seed()
    {:ok, %{}}
  end

  defp ensure_table do
    opts =
      if disc?() do
        [
          {:disc_copies, [node()]},
          attributes: [:id, :salt, :hash, :role],
          type: :set
        ]
      else
        [attributes: [:id, :salt, :hash, :role], type: :set]
      end

    case :mnesia.create_table(@table, opts) do
      {:atomic, _} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
      {:aborted, reason} -> raise "Auth: mnesia create_table failed: #{inspect(reason)}"
    end

    case :mnesia.wait_for_tables([@table], 10_000) do
      :ok -> :ok
      other -> raise "Auth: mnesia table #{@table} not ready: #{inspect(other)}"
    end
  end

  defp ensure_sessions do
    if :ets.info(@sessions) == :undefined do
      :ets.new(@sessions, [:set, :public, :named_table])
    end
  end

  defp disc?, do: HomeElixir.Mnesia.disc?()

  # ---- seeding (runs in the table-owning GenServer process) ----

  defp seed do
    users = normalize_users(Application.get_env(:home_elixir, :auth_users, []))
    ensure_admin(users)

    for {name, password, role} <- users,
        name != @admin, not reserved?(name), not exists?(name) do
      create(name, password, role || "user")
    end
  end

  # A configured admin password/role wins; otherwise a password is generated
  # and logged, and the role defaults to "admin".
  defp ensure_admin(users) do
    if exists?(@admin) do
      :ok
    else
      case List.keyfind(users, @admin, 0) do
        {_n, password, role} ->
          create(@admin, password, role || "admin")

        nil ->
          password = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
          create(@admin, password, "admin")
          Logger.info("home-elixir: no admin password configured; generated: #{password}")
      end
    end
  end

  # Accept {name, password} or {name, password, role}; drop invalid entries. A
  # 2-tuple leaves the role nil so the caller can pick the default ("user" for
  # regular accounts, "admin" for the built-in admin).
  defp normalize_users(list) when is_list(list),
    do: list |> Enum.map(&user_tuple/1) |> Enum.reject(&is_nil/1)

  defp normalize_users(map) when is_map(map), do: Map.to_list(map) |> normalize_users()
  defp normalize_users(_), do: []

  defp user_tuple({name, password, role}) when is_binary(name) and is_binary(password),
    do: {name, password, if(role in ~w(admin user), do: role, else: "user")}

  defp user_tuple({name, password}) when is_binary(name) and is_binary(password),
    do: {name, password, nil}

  defp user_tuple(_), do: nil

  defp create(name, password, role) do
    {salt, hash} = hash_password(password)
    tx(fn -> :mnesia.write(rec(name, salt, hash, role)) end)
    :ok
  end

  # The all-users owner sentinel can't double as a username.
  defp reserved?(name), do: name == HomeElixir.FlowState.public_owner()

  # ---- public user CRUD (GenServer calls run in the owning process) ----

  def create_user(name, password, role \\ "user"),
    do: GenServer.call(__MODULE__, {:create, name, password, role})

  def delete_user(name), do: GenServer.call(__MODULE__, {:delete, name})

  # Admin-only: set a new password without knowing the old one.
  def reset_password(name, password), do: GenServer.call(__MODULE__, {:reset_password, name, password})

  # Admin only: set a user's role ("admin" or "user"). The built-in admin
  # account can't be changed (prevents locking out the guaranteed admin).
  def set_role(name, role), do: GenServer.call(__MODULE__, {:set_role, name, role})

  # Self-service: requires the current password.
  def change_password(name, old, new),
    do: GenServer.call(__MODULE__, {:change_password, name, old, new})

  @doc "All users as [%{name, role}]."
  def list_users, do: GenServer.call(__MODULE__, :list_users)

  # ---- login (callable from any process) ----

  @doc "Auto-authenticate a user from HA ingress (X-Remote-User-Name). Creates them if new."
  def ensure_ha_user(name) do
    case read_user(name) do
      {_name, _salt, _hash, role} -> {name, role}
      _ ->
        # New HA user — create with admin role (HA owner = add-on admin)
        case create(name, :crypto.strong_rand_bytes(16) |> Base.encode64(), "admin") do
          {:ok, _} -> {name, "admin"}
          {:error, _} -> {name, "admin"}
        end
    end
  end

  @doc "Verify a local username/password; returns `{:ok, {username, role}}`."
  def login(username, password) do
    case read_user(username) do
      {_name, salt, hash, role} ->
        if check_password?(password, salt, hash) do
          {:ok, {username, role}}
        else
          {:error, :bad_credentials}
        end

      _ ->
        {:error, :bad_credentials}
    end
  end

  @doc """
  Validate an HA token: resolves its identity via HA's WebSocket
  `auth/current_user` and maps `is_admin` to the local `admin` role.
  """
  def login_ha_token(token) do
    case HomeElixir.HA.whoami(token) do
      {:ok, {name, is_admin}} ->
        case ha_identity(name, is_admin) do
          {:error, :reserved_name} = err ->
            Logger.warning("rejecting Home Assistant login for reserved username #{inspect(name)}")
            err

          other -> other
        end

      {:error, _} ->
        {:error, :bad_credentials}
    end
  end

  # Map a resolved HA identity to a login result, rejecting the reserved
  # all-users name (which would otherwise make any flow it saves leak to
  # everyone).
  def ha_identity(name, is_admin) do
    if reserved?(name) do
      {:error, :reserved_name}
    else
      {:ok, {name, if(is_admin, do: "admin", else: "user")}}
    end
  end

  # ---- sessions (ETS) ----

  @doc "Create a session for a user; returns the opaque token to store in a cookie."
  def create_session(user_id, role) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    :ets.insert(@sessions, {token, user_id, role, expiry()})
    token
  end

  @doc "Resolve a session token to `{user_id, role}` or `{:error, :unauthorized}`."
  def resolve_session(token) when is_binary(token) do
    case :ets.lookup(@sessions, token) do
      [{^token, user_id, role, exp}] ->
        if System.system_time(:second) < exp do
          {:ok, {user_id, role}}
        else
          :ets.delete(token)
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def resolve_session(_), do: {:error, :unauthorized}

  @doc "Drop a session token (logout / user deletion)."
  def delete_session(token) when is_binary(token) do
    :ets.delete(@sessions, token)
    :ok
  end

  def delete_session(_), do: :ok

  # Drop every live session for a user (used on delete and on role change, so a
  # stale role or deleted account can't outlive the change in an open session).
  defp drop_sessions_for(name) do
    :ets.tab2list(@sessions)
    |> Enum.filter(fn {_token, uid, _role, _exp} -> uid == name end)
    |> Enum.each(fn {token, _uid, _role, _exp} -> :ets.delete(@sessions, token) end)
  end

  @doc "The session cookie name."
  def cookie_name, do: @cookie

  # Read the current user from a Plug.Conn's session cookie (cookies must be
  # fetched, which HomeElixir.AuthGuard does for every request).
  def user_from_conn(conn) do
    case conn.cookies[cookie_name()] do
      nil -> {:error, :unauthorized}
      token -> resolve_session(token)
    end
  end

  defp expiry do
    hours = Application.get_env(:home_elixir, :session_ttl_h, 168)
    System.system_time(:second) + hours * 3600
  end

  # ---- internals ----

  defp hash_password(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    {salt, :crypto.pbkdf2_hmac(@key, password, salt, @iterations, 32)}
  end

  defp check_password?(password, salt, stored_hash) do
    # Local, trusted-network service: a plain == on the derived key is fine.
    :crypto.pbkdf2_hmac(@key, password, salt, @iterations, 32) == stored_hash
  end

  defp tx(fun), do: HomeElixir.Mnesia.tx("Auth", fun)

  # {id, salt, hash, role} or nil.
  defp read_user(name) do
    case tx(fn -> :mnesia.read(@table, name) end) do
      [{_tag, id, salt, hash, role}] -> {id, salt, hash, role}
      _ -> nil
    end
  end

  defp exists?(name), do: tx(fn -> :mnesia.read(@table, name) end) != []

  # ---- GenServer handlers (user CRUD) ----

  def handle_call({:create, name, password, role}, _from, state) do
    cond do
      reserved?(name) -> {:reply, {:error, "reserved username"}, state}
      exists?(name) -> {:reply, {:error, :exists}, state}

      true ->
        create(name, password, role)
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    if name == @admin do
      {:reply, {:error, "cannot delete the admin account"}, state}
    else
      # Re-home this user's flows to admin-only first, so they don't silently
      # vanish (owned by a user that no longer exists) once the account is gone.
      HomeElixir.FlowState.owned_flow_names(name)
      |> Enum.each(&HomeElixir.FlowState.clear_flow_owner/1)

      tx(fn -> :mnesia.delete(@table, name, :write) end)
      drop_sessions_for(name)
      {:reply, :ok, state}
    end
  end

  def handle_call({:reset_password, name, password}, _from, state) do
    case read_user(name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {id, _salt, _hash, role} ->
        {salt, hash} = hash_password(password)
        tx(fn -> :mnesia.write(rec(id, salt, hash, role)) end)
        {:reply, :ok, state}
    end
  end

  def handle_call({:change_password, name, old, new}, _from, state) do
    case read_user(name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {id, salt, hash, role} ->
        if check_password?(old, salt, hash) do
          {ns, nh} = hash_password(new)
          tx(fn -> :mnesia.write(rec(id, ns, nh, role)) end)
          {:reply, :ok, state}
        else
          {:reply, {:error, :bad_password}, state}
        end
    end
  end

  def handle_call({:set_role, name, role}, _from, state) do
    cond do
      role not in ~w(admin user) ->
        {:reply, {:error, :bad_role}, state}

      name == @admin ->
        {:reply, {:error, "cannot change the admin account's role"}, state}

      true ->
        case read_user(name) do
          nil ->
            {:reply, {:error, :not_found}, state}

          {id, salt, hash, _role} ->
            tx(fn -> :mnesia.write(rec(id, salt, hash, role)) end)
            # The role is baked into live sessions; drop them so the new role
            # applies on next login (a demotion can't linger for up to the TTL).
            drop_sessions_for(name)
            {:reply, :ok, state}
        end
    end
  end

  def handle_call(:list_users, _from, state) do
    users =
      tx(fn -> :mnesia.match_object({@table, :_, :_, :_, :_}) end)
      |> Enum.map(fn {_, id, _salt, _hash, role} -> %{name: id, role: role} end)
      |> Enum.sort_by(& &1.name)

    {:reply, users, state}
  end
end
