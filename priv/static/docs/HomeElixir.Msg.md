# `HomeElixir.Msg`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/msg.ex#L1)

A message flowing through a flow, Node-RED-style. `payload` is the primary
value; `topic` and `data` carry metadata; extra fields live in `data`.

# `t`

```elixir
@type t() :: %HomeElixir.Msg{
  data: map(),
  msgid: term(),
  payload: term(),
  topic: term()
}
```

# `new`

Build a message: `Msg.new("hi", topic: "x")`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
