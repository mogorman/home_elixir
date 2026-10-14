defmodule HomeElixir.Nodes.Schedule do
  @moduledoc """
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
  """
  @behaviour HomeElixir.Node

  alias HomeElixir.Msg

  @impl true
  def init(config) do
    cron = config[:cron] || raise "Schedule node requires `cron` (5-field cron expression)"
    expr = Crontab.CronExpression.Parser.parse!(cron)

    %{
      cron: cron,
      expr: expr,
      payload: config[:payload] || "fire",
      topic: config[:topic] || "schedule"
    }
    |> arm()
  end

  @impl true
  def handle(_msg, state), do: {[nil], state}

  @impl true
  def trigger(:cron_tick, state) do
    {[%Msg{payload: state.payload, topic: state.topic}], arm(state)}
  end

  def trigger(_other, state), do: {[nil], state}

  # Schedule the next fire (wall-clock) and keep the node state unchanged.
  defp arm(%{expr: expr} = state) do
    now_ms = System.system_time(:millisecond)

    delay =
      case next_future_ms(expr, now_naive(), now_ms) do
        nil -> 60_000
        abs -> max(0, abs - now_ms)
      end

    Process.send_after(self(), :cron_tick, delay)
    state
  end

  # Next wall-clock run strictly in the future, as absolute system ms (nil for a
  # nonexistent local time / DST gap). crontab returns the current minute when
  # "now" sits exactly on a boundary, which would give a 0 delay and a tight
  # refire loop; recompute from 1s later to force the next matching minute.
  @doc false
  def next_future_ms(expr, now_ndt, now_ms) do
    next = Crontab.Scheduler.get_next_run_date!(expr, now_ndt)

    case naive_to_system_ms(next) do
      ms when is_integer(ms) and ms > now_ms ->
        ms

      _ ->
        Crontab.Scheduler.get_next_run_date!(expr, NaiveDateTime.add(next, 1, :second))
        |> naive_to_system_ms()
    end
  end

  # Local wall-clock now as a NaiveDateTime (this machine's local time).
  defp now_naive do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
    NaiveDateTime.new!(Date.new!(y, mo, d), Time.new!(h, mi, s))
  end

  # Local wall-clock NaiveDateTime -> absolute system time in ms. Returns nil
  # for a nonexistent local time (DST spring-forward gap) so the caller can
  # retry instead of crashing.
  @doc false
  def naive_to_system_ms(%NaiveDateTime{
        year: y,
        month: mo,
        day: d,
        hour: h,
        minute: mi,
        second: s
      }) do
    case :calendar.local_time_to_universal_time_dst({{y, mo, d}, {h, mi, s}}) do
      [utc | _] -> :calendar.universal_time_to_system_time(utc) * 1000
      [] -> nil
    end
  end
end
