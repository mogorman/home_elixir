defmodule HomeElixir.Flows.Examples.NowClock do
  @moduledoc """
  Example: a flow that uses an external Hex library (`timex`), installed at load
  time via `setup/0` (Livebook-style) — without editing `mix.exs`.

  - `setup/0` runs once when the flow is loaded and pulls `timex` onto the
    code path via `HomeElixir.Dep.install/1`.
  - A "What time is it?" button on the /controls page fires the flow; a
    Function node formats the current time with timex and logs it.

  No Home Assistant needed.
  """
  use HomeElixir.Flow

  def setup, do: HomeElixir.Dep.install([{:timex, "~> 3.7"}])

  def now(msg) do
    t = Timex.now() |> Timex.format!("{h12}:{m} {am}")
    %{msg | payload: "It is now #{t}"}
  end

  node("trigger", HomeElixir.Nodes.Inject, ui: %{type: "button", label: "What time is it?"})
  node("clock", HomeElixir.Nodes.Function, fun: &__MODULE__.now/1)
  node("log", HomeElixir.Nodes.Logger)
  wire("trigger", "clock")
  wire("clock", "log")
end
