# `HomeElixir.Examples`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/examples.ex#L1)

Bundled example flows, kept in a separate read-only `examples/` dir (outside the
user's `flows/` dir). They can be listed, viewed, and copied into the user's
flows (verbatim) so they can be edited. They are never loaded or run in place.

# `copy`

Copy an example flow, verbatim, into the user's flows dir under the same base
name. Returns `{:ok, name}`, or `{:error, :exists}` / `{:error, :not_found}`.

# `list`

All example flows as `%{name, path}`, sorted by name.

# `source`

The source of one example flow, or `{:error, :not_found}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
