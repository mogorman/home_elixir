# `HomeElixir.Auth`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/auth.ex#L1)

Local accounts (Mnesia), in-memory sessions (ETS), and PBKDF2 password
hashing via OTP `:crypto` — no external deps, so the hermetic Nix build is
untouched.

On start it seeds accounts from `:home_elixir, :auth_users` (username =>
password) and always ensures an `admin`: its password from that config, or a
freshly generated one (printed to the log) when none is configured.

A user logs in with a local password (`login/2`) or a Home Assistant token
(`login_ha_token/1`), whose identity and role are resolved via HA's WebSocket
`auth/current_user` (`is_admin` maps to the local `admin` role).

# `change_password`

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `cookie_name`

The session cookie name.

# `create_session`

Create a session for a user; returns the opaque token to store in a cookie.

# `create_user`

# `delete_session`

Drop a session token (logout / user deletion).

# `delete_user`

# `ensure_ha_user`

Auto-authenticate a user from HA ingress (X-Remote-User-Name). Creates them if new.

# `ha_identity`

# `list_users`

All users as [%{name, role}].

# `login`

Verify a local username/password; returns `{:ok, {username, role}}`.

# `login_ha_token`

Validate an HA token: resolves its identity via HA's WebSocket
`auth/current_user` and maps `is_admin` to the local `admin` role.

# `reset_password`

# `resolve_session`

Resolve a session token to `{user_id, role}` or `{:error, :unauthorized}`.

# `set_role`

# `start_link`

# `user_from_conn`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
