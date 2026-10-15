defmodule HomeElixir.FlowsHATest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{FlowStore, HA, FlowsHA}
  alias HA.FakeTransport

  @name :test_flows_ha

  @alpha """
  defmodule HomeElixir.Flows.FlowsHATestAlpha do
    use HomeElixir.Flow

    node("out", HomeElixir.Nodes.Sink)
  end
  """

  @beta """
  defmodule HomeElixir.Flows.FlowsHATestBeta do
    use HomeElixir.Flow

    node("out", HomeElixir.Nodes.Sink)
  end
  """

  setup do
    HomeElixir.FlowState.start()
    tmp = Path.join(System.tmp_dir!(), "flows_ha_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "alpha.ex"), @alpha)
    File.write!(Path.join(tmp, "beta.ex"), @beta)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      stop_flows_ha()
      FlowStore.unload("alpha")
      FlowStore.unload("beta")
      stop_ha()
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  # ---- helpers ----

  defp start_ha! do
    {:ok, client} =
      HA.Client.start_link(
        name: HA.client_name(),
        url: "ws://fake:8123/api/websocket",
        token: "tok",
        transport: FakeTransport,
        reconnect_delay: 10
      )

    t = HA.Client.transport_pid(client)
    FakeTransport.connected(t)
    FakeTransport.send_text(t, ~s({"type":"auth_ok"}))
    wait_status(client, :connected)
    %{client: client, t: t}
  end

  # An isolated FlowsHA (distinct name from the app's) so it never collides with
  # the supervised one, and each test gets a clean slate (cleaned: false).
  defp start_flows_ha! do
    stop_flows_ha()
    wait_nil(@name)
    {:ok, _} = GenServer.start_link(FlowsHA, name: @name)
  end

  defp stop_flows_ha do
    if pid = GenServer.whereis(@name), do: GenServer.stop(pid, :normal)
  end

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client, :normal)
  end

  defp wait_status(client, status), do: poll(fn -> HA.Client.status(client) == status end)

  defp wait_nil(name) do
    poll(fn -> is_nil(GenServer.whereis(name)) end)
  end

  defp poll(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(2)

      if System.monotonic_time(:millisecond) < deadline do
        poll(fun)
      else
        flunk("timed out")
      end
    end
  end

  # Find an outbound frame matching a predicate over the decoded JSON.
  defp sent_frame(t, pred, remaining \\ 3_000) do
    frame =
      FakeTransport.sent(t)
      |> Enum.map(&Jason.decode!(&1))
      |> Enum.find(pred)

    case frame do
      nil when remaining > 0 ->
        Process.sleep(2)
        sent_frame(t, pred, remaining - 2)

      nil ->
        flunk("timed out waiting for a matching outbound frame")

      frame ->
        frame
    end
  end

  # Answer the boot get_states with `result` so the cleanup task can proceed.
  defp respond_get_states(t, result, remaining \\ 3_000) do
    gs =
      FakeTransport.sent(t)
      |> Enum.map(&Jason.decode!(&1))
      |> Enum.find(&(&1["type"] == "get_states"))

    case gs do
      nil when remaining > 0 ->
        Process.sleep(5)
        respond_get_states(t, result, remaining - 5)

      %{"id" => id} ->
        FakeTransport.send_text(
          t,
          Jason.encode!(%{"id" => id, "type" => "result", "success" => true, "result" => result})
        )
    end
  end

  # ---- tests ----

  test "discovers one switch per flow under a single Flows device" do
    %{t: t} = start_ha!()
    start_flows_ha!()

    a = sent_frame(t, &(&1["type"] == "nodered/discovery" and &1["node_id"] == "alpha"))
    assert a["component"] == "switch"
    assert a["server_id"] == "home_elixir"
    assert a["config"]["name"] == "alpha"
    assert a["device_info"]["id"] == "home_elixir_flows"
    assert a["attributes"]["__he"] == "flows/alpha"
    # State is not baked into discovery (it is pushed via nodered/entity), so a
    # re-discovery can never pin the entity to a stale loaded state.
    assert Map.get(a, "state") == nil

    b = sent_frame(t, &(&1["type"] == "nodered/discovery" and &1["node_id"] == "beta"))
    assert b["device_info"]["id"] == "home_elixir_flows"
  end

  test "toggling a switch on loads the flow and reports state true" do
    %{t: t} = start_ha!()
    start_flows_ha!()

    id = sent_frame(t, &(&1["type"] == "nodered/discovery" and &1["node_id"] == "alpha"))["id"]
    FakeTransport.send_text(t, Jason.encode!(event(id, "on")))

    poll(fn -> FlowStore.loaded?("alpha") end)

    ent =
      sent_frame(
        t,
        &(&1["type"] == "nodered/entity" and &1["node_id"] == "alpha" and &1["state"] == true)
      )

    assert ent["server_id"] == "home_elixir"
  end

  test "toggling a switch off unloads the flow and reports state false" do
    %{t: t} = start_ha!()
    start_flows_ha!()
    assert :ok = FlowStore.load("beta")

    id = sent_frame(t, &(&1["type"] == "nodered/discovery" and &1["node_id"] == "beta"))["id"]
    FakeTransport.send_text(t, Jason.encode!(event(id, "off")))

    poll(fn -> not FlowStore.loaded?("beta") end)

    _ =
      sent_frame(
        t,
        &(&1["type"] == "nodered/entity" and &1["node_id"] == "beta" and &1["state"] == false)
      )
  end

  test "removes a stale HA entity whose flow file no longer exists on boot" do
    %{t: t} = start_ha!()
    start_flows_ha!()

    orphan = %{
      "entity_id" => "switch.ghost",
      "state" => "off",
      "attributes" => %{"__he" => "flows/ghost"}
    }

    respond_get_states(t, [orphan])

    _ =
      sent_frame(
        t,
        &(&1["type"] == "nodered/discovery" and &1["node_id"] == "ghost" and &1["remove"] == true)
      )
  end

  defp event(id, state) do
    %{"id" => id, "type" => "event", "event" => %{"type" => "state_changed", "state" => state}}
  end
end
