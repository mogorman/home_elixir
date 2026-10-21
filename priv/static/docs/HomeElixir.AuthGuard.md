# `HomeElixir.AuthGuard`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/auth_guard.ex#L1)

Wraps `HomeElixir.Web` and enforces a session on every route except the public
ones (`/login`, `/api/login`, static assets, favicon). On success it assigns
`conn.assigns.user = {username, role}` and hands the conn to `HomeElixir.Web`;
on failure it redirects HTML requests to `/login` and answers `/api/*` with 401.

# `call`

# `init`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
