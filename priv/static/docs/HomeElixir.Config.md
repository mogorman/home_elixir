# `HomeElixir.Config`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/config.ex#L1)

Layered, editable configuration for flows.

Resolution order (first hit wins):

  1. flow-specific value — set in the UI, or seeded by the flow's `setup/0`
  2. global value — shared across all flows
  3. `Application.get_env(:home_elixir, key)` — config/*.exs (e.g. secret.exs)
  4. `System.get_env("KEY")` — an environment variable
  5. the supplied default

Read it from inside a flow — the current flow is the ambient context set by
the node engine and `setup/0`, so no flow argument is needed:

    HomeElixir.Config.get(:llm_url, "http://localhost:42808/v1")

Flows declare their editable keys (and defaults) in `setup/0` so they appear
in the UI and can be overridden without editing code:

    def setup do
      HomeElixir.Config.seed(%{llm_url: "http://localhost:42808/v1"})
      HomeElixir.Config.seed(%{llm_api_key: "sk-..."}, scope: :global)
    end

`seed/2` is only-if-absent, so a value a user later edits in the UI survives
flow reloads and restarts. Backed by Mnesia (started by `HomeElixir.Application`
before any flow loads).

# `delete`

Remove a value for a scope — subsequent reads fall back to the next layer.

# `flow_config`

All flow-specific config for a flow (name => %{key => value}).

# `get`

Resolve a config value per the layered order. Returns the value.

# `global_config`

All global config (%{key => value}).

# `put`

Set a value for a scope — a flow name or `:global`.

# `put_flow`

Set a flow-specific value for the current (ambient) flow.

# `put_global`

Set a global value (shared across all flows).

# `resolve`

Resolve a config value, returning `{value, source}` where source is one of
`:flow`, `:global`, `:app`, `:system`, or `:default`. Used by the UI to badge
where each value comes from.

# `secret?`

# `seed`

Declare editable keys + defaults for the current flow. `scope:` defaults to
`:flow` (per-flow); pass `scope: :global` for values shared across flows.
Only-if-absent across the whole resolution chain, so it never shadows a value
already set at any layer (flow/global/app/system) — a user's edit or app
config always wins over a re-seed.

# `start`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
