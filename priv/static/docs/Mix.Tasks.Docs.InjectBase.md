# `mix docs.inject_base`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/mix/tasks/docs.inject_base.ex#L1)

Injects a client-side `<base href="<base>/static/docs/">` into each
`priv/static/docs/*.html` right after `<head>`.

The ExDoc site is a static sub-site. Its links are relative, so they only
resolve correctly when the browser's URL already carries the sub-path. Setting
an explicit `<base>` anchored at the site's own root makes it work under any
reverse-proxy / HA-ingress prefix (the prefix is computed in the browser, since
behind HA ingress the supervisor only reveals it client-side).

# `run`

```elixir
@spec run([String.t()]) :: :ok
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
