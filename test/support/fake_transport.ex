defmodule HomeElixir.HA.FakeTransport do
  @moduledoc "A controllable transport for tests. No network; the test drives it."

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.get(opts, :owner), out: []}}

  @impl true
  def handle_cast({:ha_send, json}, state), do: {:noreply, %{state | out: [json | state.out]}}

  # ---- Test drivers ----

  def connected(pid), do: send(pid, :test_connected)
  def send_text(pid, json), do: send(pid, {:test_text, json})
  def close(pid), do: send(pid, :test_close)
  def sent(pid), do: GenServer.call(pid, :sent)

  @impl true
  def handle_info(:test_connected, state) do
    send(state.owner, {:ha_transport, :connected})
    {:noreply, state}
  end

  def handle_info({:test_text, json}, state) do
    send(state.owner, {:ha_transport, :text, json})
    {:noreply, state}
  end

  def handle_info(:test_close, state) do
    send(state.owner, {:ha_transport, :closed, :test})
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:sent, _from, state), do: {:reply, Enum.reverse(state.out), state}
end
