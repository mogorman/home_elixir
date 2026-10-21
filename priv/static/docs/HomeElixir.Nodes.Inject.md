# `HomeElixir.Nodes.Inject`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/inject.ex#L1)

Passthrough source node: re-emits each incoming message unchanged. Use it as
the entry point of a flow that starts from an external trigger (a web button
via the `ui:` config) rather than from an HA event.

Pair it with a `ui:` config so the web UI renders a control for it:

    node("start", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "Go"})
    wire("start", "next")

---

*Consult [api-reference.md](api-reference.md) for complete listing*
