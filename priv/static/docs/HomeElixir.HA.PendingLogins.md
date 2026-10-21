# `HomeElixir.HA.PendingLogins`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/ha/pending_logins.ex#L1)

Shared store for in-flight OAuth logins, keyed by the `state` value.

A named GenServer so the mapping survives across Cowboy worker processes
(each HTTP request runs in a short-lived worker; the state minted at
`/oauth/start` must still be findable at `/oauth/callback`).

Each entry is `{code_verifier, expiry_ms}` and is consumed exactly once
(taken on read), so a captured redirect URL cannot be replayed.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `get`

Non-destructively read the verifier for `state` (nil if absent/expired).

# `put`

Store a pending `state` → `code_verifier`, valid for `ttl_ms`.

# `start_link`

# `take`

Atomically fetch-and-delete the verifier for `state` (nil if absent/expired).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
