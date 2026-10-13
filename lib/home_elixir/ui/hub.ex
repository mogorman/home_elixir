defmodule HomeElixir.UI.Hub do
  @moduledoc false
  # Fan-out of live updates (UI state + log lines) to connected web-socket clients.
  # Every push is tagged with a `type` the frontend dispatches on. Clients are
  # monitored and reaped on disconnect.
  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Register a client pid to receive `{:ui_push, json}` messages."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Send a tagged update (`type` + payload map) to all subscribed clients."
  def push(type, payload), do: GenServer.cast(__MODULE__, {:push, type, payload})

  @impl true
  def init(_), do: {:ok, %{clients: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | clients: Map.put(state.clients, pid, ref)}}
  end

  @impl true
  def handle_cast({:push, type, payload}, state) do
    json = Jason.encode!(%{type: type} |> Map.merge(payload))
    for pid <- Map.keys(state.clients), do: send(pid, {:ui_push, json})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, _type, _pid}, state) do
    clients = Map.reject(state.clients, fn {_pid, r} -> r == ref end)
    {:noreply, %{state | clients: clients}}
  end

  # A send to a just-dead client bounces back as {pid, msg} before its :DOWN is
  # processed; ignore it (the :DOWN reaps the client).
  def handle_info(_other, state), do: {:noreply, state}
end
