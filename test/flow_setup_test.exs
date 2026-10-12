defmodule HomeElixir.FlowSetupTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.Registry

  defmodule WithSetup do
    use HomeElixir.Flow

    # A stand-in for `Mix.install/1`: marks that setup ran, without any network.
    def setup, do: Application.put_env(:home_elixir, :setup_ran, __MODULE__)

    node("s", HomeElixir.Nodes.Sink)
  end

  defmodule NoSetup do
    use HomeElixir.Flow
    node("s", HomeElixir.Nodes.Sink)
  end

  test "setup/0 runs when the flow loads" do
    Application.delete_env(:home_elixir, :setup_ran)
    {:ok, _} = Registry.load(WithSetup)

    try do
      assert Application.get_env(:home_elixir, :setup_ran) == WithSetup
    after
      Registry.unload(WithSetup)
    end
  end

  test "a flow without setup/0 still loads" do
    Application.delete_env(:home_elixir, :setup_ran)
    {:ok, _} = Registry.load(NoSetup)

    try do
      assert is_nil(Application.get_env(:home_elixir, :setup_ran))
    after
      Registry.unload(NoSetup)
    end
  end
end
