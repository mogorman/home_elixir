defmodule HomeElixir.NodeRedTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{HA, FlowStore, FlowsHA, NodeRedStatus, Registry}
  alias HA.FakeTransport

  @flows_ha_name :test_node_red_flows_ha

  # A flow that presents a device (needs the Node-RED Companion) and one that
  # doesn't, for the FlowStore `nodered` flag.
  @device_flow """
  defmodule HomeElixir.Flows.NR.DeviceFlow do
    use HomeElixir.Flow
    node("dev", HomeElixir.Nodes.Device, server_id: "s", node_id: "n", state: false)
  end
  """

  @plain_flow """
  defmodule HomeElixir.Flows.NR.PlainFlow do
    use HomeElixir.Flow
    node("out", HomeElixir.Nodes.Sink)
  end
  """

  defmodule Flows.NR.LoadDevice do
    use HomeElixir.Flow

    node("dev", HomeElixir.Nodes.Device, server_id: "s", node_id: "n", state: false)
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

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client, :normal)
  end

  defp stop_prober do
    if pid = GenServer.whereis(NodeRedStatus), do: GenServer.stop(pid, :normal)
  end

  # Start the default prober and drive it to a locked status by answering its
  # one `nodered/version` probe with an unknown-command error. Returns the (now
  # settled) status.
  defp prober_absent!(t) do
    stop_prober()
    wait_nil(NodeRedStatus)
    {:ok, _} = NodeRedStatus.start_link()
    req = sent_until(t, &(&1 =~ "nodered/version"))

    FakeTransport.send_text(
      t,
      Jason.encode!(%{
        "id" => req["id"],
        "type" => "result",
        "success" => false,
        "error" => %{"code" => "unknown_command", "message" => "Unknown command."}
      })
    )

    poll(fn -> NodeRedStatus.status() == :absent end)
    :absent
  end

  defp wait_status(client, status), do: poll(fn -> HA.Client.status(client) == status end)

  defp wait_nil(name), do: poll(fn -> is_nil(GenServer.whereis(name)) end)

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

  defp sent_until(transport, pred, remaining \\ 3_000) do
    case Enum.find(FakeTransport.sent(transport), pred) do
      nil when remaining > 0 ->
        Process.sleep(1)
        sent_until(transport, pred, remaining - 1)

      nil ->
        flunk("timed out waiting for an outbound frame")

      json ->
        Jason.decode!(json)
    end
  end

  defp tmp_flows!(files) do
    HomeElixir.FlowState.start()

    tmp = Path.join(System.tmp_dir!(), "nr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Enum.each(files, fn {name, src} -> File.write!(Path.join(tmp, name), src) end)
    Application.put_env(:home_elixir, :flows_dir, tmp)

    on_exit(fn ->
      Application.put_env(:home_elixir, :flows_dir, "flows")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  # ---- tests ----

  test "status is unknown when the prober isn't running" do
    stop_ha()
    stop_prober()
    assert NodeRedStatus.status() == :unknown
  end

  test "recheck reports unknown with no HA client" do
    stop_ha()
    stop_prober()
    wait_nil(NodeRedStatus)
    {:ok, _} = NodeRedStatus.start_link()
    assert GenServer.call(NodeRedStatus, :recheck) == :unknown
    stop_prober()
  end

  test "probe reports loaded when the nodered/version command replies" do
    %{t: t} = start_ha!()
    on_exit(fn -> stop_ha() end)

    stop_prober()
    wait_nil(NodeRedStatus)
    {:ok, _} = NodeRedStatus.start_link()

    req = sent_until(t, &(&1 =~ "nodered/version"))

    FakeTransport.send_text(
      t,
      Jason.encode!(%{
        "id" => req["id"],
        "type" => "result",
        "success" => true,
        "result" => "4.3.2"
      })
    )

    poll(fn -> NodeRedStatus.status() == :loaded end)
    stop_prober()
  end

  test "probe reports absent when the nodered/version command is unknown" do
    %{t: t} = start_ha!()
    on_exit(fn -> stop_ha() end)
    assert prober_absent!(t) == :absent
    stop_prober()
  end

  test "device node skips discovery when the companion is absent" do
    %{t: t} = start_ha!()
    on_exit(fn -> Registry.unload(Flows.NR.LoadDevice); stop_ha() end)
    prober_absent!(t)

    {:ok, _} = Registry.load(Flows.NR.LoadDevice)

    assert not Enum.any?(FakeTransport.sent(t), &(&1 =~ "nodered/discovery"))
  end

  test "FlowsHA does not sync switches when the companion is absent" do
    %{t: t} = start_ha!()
    on_exit(fn ->
      if pid = GenServer.whereis(@flows_ha_name), do: GenServer.stop(pid, :normal)
      stop_ha()
    end)

    prober_absent!(t)
    tmp_flows!(%{"device_flow.ex" => @device_flow, "plain_flow.ex" => @plain_flow})

    if pid = GenServer.whereis(@flows_ha_name), do: GenServer.stop(pid, :normal)
    wait_nil(@flows_ha_name)
    {:ok, hapid} = GenServer.start_link(FlowsHA, name: @flows_ha_name)

    # Nudge a reconcile (normally triggered on flow_changed) and let the timer fire.
    send(hapid, {:ui_push, Jason.encode!(%{"type" => "flow_changed"})})
    Process.sleep(650)

    assert not Enum.any?(FakeTransport.sent(t), &(&1 =~ "nodered/discovery"))
  end

  test "FlowStore marks device flows nodered: true" do
    tmp_flows!(%{"device_flow.ex" => @device_flow, "plain_flow.ex" => @plain_flow})

    dev = Enum.find(FlowStore.list(), &(&1.name == "device_flow"))
    plain = Enum.find(FlowStore.list(), &(&1.name == "plain_flow"))

    assert dev.nodered == true
    assert plain.nodered == false
  end
end
