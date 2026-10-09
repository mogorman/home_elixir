defmodule HomeElixir.LogTest do
  use ExUnit.Case, async: false

  test "records lines and tails them back" do
    GenServer.cast(HomeElixir.Log, {:line, :info, "logtest-alpha"})
    GenServer.cast(HomeElixir.Log, {:line, :error, "logtest-beta"})

    texts = HomeElixir.Log.lines(0) |> Enum.map(&elem(&1, 1))
    assert "info  logtest-alpha" in texts
    assert "error  logtest-beta" in texts
  end
end
