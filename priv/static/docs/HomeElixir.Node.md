# `HomeElixir.Node`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/node.ex#L1)

Behaviour for flow nodes.

`handle/2` turns one incoming message into a list of output messages; the
engine currently forwards output index 0 only (multi-output is a later add).
`init/1` is optional — a node that does not define it starts with state `nil`.

`trigger/2` is optional for source/in nodes: it is called with an external
event (e.g. `{:ha_event, ref, event}`) so the node can emit messages without
an input.

# `msg`

```elixir
@type msg() :: HomeElixir.Msg.t()
```

# `outputs`

```elixir
@type outputs() :: [msg() | nil]
```

# `state`

```elixir
@type state() :: term()
```

# `handle`

```elixir
@callback handle(msg(), state()) :: {outputs(), state()}
```

# `init`
*optional* 

```elixir
@callback init(config :: term()) :: state()
```

# `trigger`
*optional* 

```elixir
@callback trigger(event :: term(), state()) :: {outputs(), state()}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
