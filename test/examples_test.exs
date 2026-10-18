defmodule HomeElixir.ExamplesTest do
  use ExUnit.Case, async: false

  alias HomeElixir.Examples

  setup do
    Application.put_env(:home_elixir, :examples_dir, Path.expand("../examples", __DIR__))

    flows_tmp =
      Path.join(System.tmp_dir!(), "examples_test_flows_#{System.unique_integer([:positive])}")

    File.mkdir_p!(flows_tmp)
    Application.put_env(:home_elixir, :flows_dir, flows_tmp)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(flows_tmp)
    end)

    :ok
  end

  test "lists the bundled examples by name" do
    names = Examples.list() |> Enum.map(& &1.name)
    assert "counter" in names
    assert "watch_all" in names
  end

  test "returns source for a known example and errors for unknown" do
    assert {:ok, src} = Examples.source("counter")
    assert src =~ "defmodule"
    assert {:error, :not_found} = Examples.source("nope")
  end

  test "copies an example into flows verbatim, and errors on collision/unknown" do
    flows_dir = Application.get_env(:home_elixir, :flows_dir)

    assert {:ok, "counter"} = Examples.copy("counter")
    dest = Path.join(flows_dir, "counter.ex")
    assert File.exists?(dest)
    assert File.read!(dest) == elem(Examples.source("counter"), 1)

    assert {:error, :exists} = Examples.copy("counter")
    assert {:error, :not_found} = Examples.copy("nope")
  end
end
