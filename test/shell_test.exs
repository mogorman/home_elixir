defmodule HomeElixir.ShellTest do
  use ExUnit.Case, async: false

  alias HomeElixir.Shell

  setup do
    Shell.reset()
    :ok
  end

  test "returns the value of an expression" do
    assert Shell.eval("1 + 1") =~ "2"
  end

  test "persists variable bindings across lines" do
    Shell.eval("x = 41")
    assert Shell.eval("x + 1") =~ "42"
  end

  test "shows the value of inspect/1 for viewing data" do
    assert Shell.eval("inspect([1, 2])") =~ "[1, 2]"
  end

  test "reports errors without crashing the shell" do
    assert Shell.eval("1/0") =~ ~r/Arithmetic|error/i
    assert Shell.eval("this_is_not_a_variable") =~ ~r/undefined|error|match|Compile/i
    # shell still works after errors
    assert Shell.eval("2 * 3") =~ "6"
  end

  test "reset clears bindings" do
    Shell.eval("y = 1")
    Shell.reset()
    assert Shell.eval("y") =~ ~r/UndefinedFunction|error|match/i
  end
end
