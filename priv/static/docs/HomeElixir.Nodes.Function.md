# `HomeElixir.Nodes.Function`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/function.ex#L1)

Applies a function to each message. Config is `fun: &Mod.fun/1` (a remote
function). It receives the `HomeElixir.Msg` and returns a new `Msg` (or a raw
value, wrapped as `payload`), or `nil` to drop the message.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
