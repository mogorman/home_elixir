defmodule HomeElixir.UI.HubTest do
  use ExUnit.Case, async: false

  alias HomeElixir.UI.Hub

  setup_all do
    # The hub runs with the app; start a standalone one if the app isn't booted.
    if Process.whereis(Hub) == nil do
      GenServer.start(Hub, [], name: Hub)
    end

    :ok
  end

  test "push delivers a type-tagged json update to a subscribed client" do
    Hub.subscribe(self())
    Hub.push(:state, %{flow: "counter", node: "count", value: 7})
    assert_receive {:ui_push, json}, 500
    assert %{"type" => "state", "flow" => "counter", "node" => "count", "value" => 7} =
             Jason.decode!(json)
  end

  test "a disconnected client is reaped, surviving clients still receive" do
    me = self()

    other =
      spawn(fn ->
        Hub.subscribe(self())
        send(me, :subbed)
        receive do
          :kill -> :ok
        end
      end)

    assert_receive :subbed, 1000
    Hub.subscribe(me)

    # Kill the other client; the hub should drop it on :DOWN.
    send(other, :kill)
    Process.sleep(50)

    Hub.push(:log, %{id: 1, line: "info  hello"})
    assert_receive {:ui_push, _json}, 500
  end
end
