# `HomeElixir.Nodes.Schedule`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/nodes/schedule.ex#L1)

Source node: fires on wall-clock times given by a 5-field cron expression
(e.g. `"*/2 * * * *"` every 2 minutes, `"0 15 * * 1"` Monday at 3pm).

Config:
  * `cron`    — 5-field cron expression (required). Invalid cron is a load-time error.
  * `payload` — term to emit (default `"fire"`).
  * `topic`   — Msg topic (default `"schedule"`).

No input wires. Each fire emits a `Msg` and reschedules the next run.
Next-run math is wall-clock / local time via `Crontab.Scheduler`.

Example (auto-increment a counter every 2 minutes):
    node("tick", HomeElixir.Nodes.Schedule, cron: "*/2 * * * *", payload: "inc")

---

*Consult [api-reference.md](api-reference.md) for complete listing*
