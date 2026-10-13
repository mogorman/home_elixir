defmodule HomeElixir.FlowHandlerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HomeElixir.{Msg, Registry, HA}
  alias HomeElixir.HA.FakeTransport

  defmodule Flows.HandlerTest do
    use HomeElixir.Flow

    def handle(%{topic: "light.kitchen", payload: "on"}) do
      Application.put_env(:home_elixir, :handler_fired, System.monotonic_time())
    end

    # No catch-all clause — the Flow macro adds it.
  end

  # "btn" has no outgoing wire (auto-wired into the handler); "explicit" is
  # wired elsewhere (must not be auto-wired).
  defmodule Flows.AutoWire do
    use HomeElixir.Flow

    def handle(%{payload: "go"}),
      do: Application.put_env(:home_elixir, :auto_fired, System.monotonic_time())

    node("btn", HomeElixir.Nodes.Inject)
    node("explicit", HomeElixir.Nodes.Inject)
    node("sink", HomeElixir.Nodes.Sink)
    wire("explicit", "sink")
  end

  # "badge" has state UI and no incoming wire (auto-fed by the handler);
  # "wired" has state UI but an explicit input (must not be auto-fed).
  defmodule Flows.AutoFeed do
    use HomeElixir.Flow

    def handle(%{payload: "go"}),
      do: Application.put_env(:home_elixir, :feed_fired, System.monotonic_time())

    node("src", HomeElixir.Nodes.Sink)
    node("wired", HomeElixir.Nodes.Sink, ui: %{type: "state", label: "W"})
    node("badge", HomeElixir.Nodes.Sink, ui: %{type: "state", label: "B"})
    wire("src", "wired")
  end

  # "probe" counts how often it is actually hit: only when the handler returns
  # a non-nil value.
  defmodule Flows.HitCounter do
    use HomeElixir.Flow

    def handle(%{payload: "inc"}), do: 1

    defmodule Probe do
      @behaviour HomeElixir.Node

      @impl true
      def init(_), do: 0

      @impl true
      def handle(_msg, n), do: {[nil], n + 1}
    end

    node("probe", __MODULE__.Probe)
    wire("__he_handle__", "probe")
  end

  # Grouped wire syntax in a plain (non-handler) flow.
  defmodule Flows.GroupWire do
    use HomeElixir.Flow

    node("a", HomeElixir.Nodes.Sink)
    node("b", HomeElixir.Nodes.Sink)
    node("c", HomeElixir.Nodes.Sink)
    wire(["a", "b"], "c")
  end

  test "unconnected Inject nodes are auto-wired into the handler; explicit wires win" do
    wires = Flows.AutoWire.__flow__().wires
    assert {"btn", "__he_handle__"} in wires
    refute {"explicit", "__he_handle__"} in wires
    assert {"explicit", "sink"} in wires
  end

  test "state-badge nodes with no input are auto-fed by the handler; explicit input wins" do
    wires = Flows.AutoFeed.__flow__().wires
    assert {"__he_handle__", "badge"} in wires
    refute {"__he_handle__", "wired"} in wires
    assert {"src", "wired"} in wires
  end

  test "handler output reaches downstream nodes only when non-nil" do
    on_exit(fn -> Registry.unload(Flows.HitCounter) end)
    {:ok, _} = Registry.load(Flows.HitCounter)

    Registry.send_msg(Flows.HitCounter, "__he_handle__", Msg.new("inc"))
    poll(fn -> Registry.node_state(Flows.HitCounter, "probe") == 1 end)

    # Unmatched payload: catch-all returns nil -> dropped, probe stays at 1.
    Registry.send_msg(Flows.HitCounter, "__he_handle__", Msg.new("zzz"))
    Process.sleep(50)
    assert Registry.node_state(Flows.HitCounter, "probe") == 1
  end

  test "group wire syntax expands to one pair per source" do
    wires = Flows.GroupWire.__flow__().wires
    assert {"a", "c"} in wires
    assert {"b", "c"} in wires
  end

  test "clicking an auto-wired button fires the handler" do
    on_exit(fn -> Registry.unload(Flows.AutoWire) end)
    Application.delete_env(:home_elixir, :auto_fired)
    {:ok, _} = Registry.load(Flows.AutoWire)

    Registry.send_msg(Flows.AutoWire, "btn", Msg.new("go", topic: "btn"))
    poll(fn -> not is_nil(Application.get_env(:home_elixir, :auto_fired)) end)
    assert Application.get_env(:home_elixir, :auto_fired)
  end

  # ---- helpers (mirrors nodes_test) ----

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
    poll(fn -> HA.Client.status(client) == :connected end)
    t
  end

  defp poll(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if fun.() do
      :ok
    else
      Process.sleep(1)

      if System.monotonic_time(:millisecond) < deadline, do: poll(fun), else: flunk("timed out")
    end
  end

  defp sent_until(transport, pred, remaining \\ 2_000) do
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

  defp emit(t, sub_id, data) do
    event = %{"event_type" => "state_changed", "data" => data}
    FakeTransport.send_text(t, Jason.encode!(%{"id" => sub_id, "type" => "event", "event" => event}))
  end

  defp stop_ha do
    if client = HA.client(), do: GenServer.stop(client)
  end

  # ---- tests ----

  test "handler flow runs handle/1 on a matching HA event" do
    t = start_ha!()
    on_exit(fn -> Registry.unload(Flows.HandlerTest); stop_ha() end)

    Application.delete_env(:home_elixir, :handler_fired)
    {:ok, _} = Registry.load(Flows.HandlerTest)
    sub = sent_until(t, &(&1 =~ "subscribe_events"))

    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    poll(fn -> not is_nil(Application.get_env(:home_elixir, :handler_fired)) end)
    assert Application.get_env(:home_elixir, :handler_fired)
  end

  test "non-matching events fall through to the macro's catch-all" do
    t = start_ha!()
    on_exit(fn -> Registry.unload(Flows.HandlerTest); stop_ha() end)

    Application.delete_env(:home_elixir, :handler_fired)
    {:ok, _} = Registry.load(Flows.HandlerTest)
    sub = sent_until(t, &(&1 =~ "subscribe_events"))

    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    poll(fn -> not is_nil(Application.get_env(:home_elixir, :handler_fired)) end)
    baseline = Application.get_env(:home_elixir, :handler_fired)

    # different entity → no re-fire
    emit(t, sub["id"], %{"entity_id" => "light.other", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "on"}})
    Process.sleep(200)
    assert Application.get_env(:home_elixir, :handler_fired) == baseline

    # same entity, different payload → no re-fire
    emit(t, sub["id"], %{"entity_id" => "light.kitchen", "old_state" => %{"state" => "off"}, "new_state" => %{"state" => "off"}})
    Process.sleep(200)
    assert Application.get_env(:home_elixir, :handler_fired) == baseline
  end
end
