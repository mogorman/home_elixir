# `HomeElixir.Log`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/log.ex#L1)

In-memory ring buffer of recent log lines, fed by `HomeElixir.LogHandler`.

The web log page polls `lines/1` for entries newer than a given id, so the
page grows as the app logs.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `init`

# `lines`

Return `[id, line]` entries with `id > since` (newest last).

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
