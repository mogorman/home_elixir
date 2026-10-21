# `HomeElixir.Dep`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/dep.ex#L1)

Install external Hex dependencies at runtime, Livebook-style, without editing
`mix.exs`.

`install/1` builds the given deps in an isolated throwaway Mix project under
the user cache — as a `mix` subprocess, since `Mix.install/1` refuses to run
inside an active Mix project — and adds the resulting code paths to the
running VM. Flows call this from their `setup/0`.

The build is cached in `~/.cache/home_elixir/deps`, so only the first install
of a dep hits the network; later loads and restarts reuse it. Because the
project is shared, `install/1` accumulates the union of all deps ever
requested, so   one flow's install never evicts another flow's compiled beams.

At boot, `reset_if_stale/0` wipes the compiled cache only when the set of
deps declared across the flow files changed since last boot — so a changed
set rebuilds clean, while an unchanged set reuses the warm cache.

# `install`

Fetch, compile, and load `deps` (a keyword list, e.g. `[{:timex, "~> 3.7"}]`).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
