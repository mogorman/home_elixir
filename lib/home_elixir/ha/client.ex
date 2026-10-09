defmodule HomeElixir.HA.Client do
  @moduledoc """
  A client for the Home Assistant WebSocket API.

  Maintains a single authenticated WebSocket connection (through a transport,
  default `HomeElixir.HA.Transport.Mint`), and offers:

    * `call/3` — id-correlated request/response
    * `subscribe_events/3` — HA event fan-out to a process
    * automatic reconnection (and re-auth + re-subscribe) after a drop

  A transport is a GenServer following a small convention: it is started with
  `module.start_link(owner: pid, url: url, token: token)`, sends
  `{:ha_transport, :connected}`, `{:ha_transport, :text, binary}` and
  `{:ha_transport, :closed, reason}` to its owner, and handles
  `GenServer.cast(transport, {:ha_send, json})` to send an outbound frame.
  """

  use GenServer

  require Logger

  alias HomeElixir.HA

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a request and await its correlated result.

  Returns the `result` field on success (may be `nil`), or
  `{:error, %{code: code, message: message}}` when Home Assistant reports an
  error. Returns `{:error, {:not_connected, status}}` if not yet connected.
  """
  def call(client, type, payload \\ %{}, timeout \\ 5_000) do
    GenServer.call(client, {:call, type, Map.new(payload || %{})}, timeout)
  end

  @doc """
  Subscribe to Home Assistant events. Matching events are sent to `to` as
  `{:ha_event, ref, event}`. Returns the subscription `ref`.
  """
  def subscribe_events(client, event_type, to, timeout \\ 5_000) do
    GenServer.call(client, {:subscribe_events, event_type, to}, timeout)
  end

  @doc "Unsubscribe a subscription returned by `subscribe_events/3`."
  def unsubscribe(client, ref, timeout \\ 5_000) do
    GenServer.call(client, {:unsubscribe, ref}, timeout)
  end

  @doc "Current connection status: `:connecting`, `:authenticating`, `:connected` or `:disconnected`."
  def status(client), do: GenServer.call(client, :status)

  @doc "The pid of the active transport (for diagnostics/tests); `nil` when down."
  def transport_pid(client), do: GenServer.call(client, :transport_pid)

  # ---- GenServer ----

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :url),
      token: Keyword.fetch!(opts, :token),
      transport_mod: Keyword.get(opts, :transport, HA.Transport.Mint),
      reconnect_delay: Keyword.get(opts, :reconnect_delay, 5_000),
      transport: nil,
      status: :disconnected,
      next_id: 1,
      pending: %{},
      subs: %{}
    }

    {:ok, ensure_transport(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:transport_pid, _from, state), do: {:reply, state.transport, state}

  def handle_call({:call, type, payload}, from, state) do
    if state.status == :connected do
      id = state.next_id
      state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}
      send_transport(state, Map.put(payload, "id", id) |> Map.put("type", type))
      # Await the correlated result; it is answered from `handle_info/2`.
      {:noreply, state}
    else
      {:reply, {:error, {:not_connected, state.status}}, state}
    end
  end

  def handle_call({:subscribe_events, event_type, to}, _from, state) do
    if state.status == :connected do
      id = state.next_id
      state = %{state | next_id: id + 1, subs: Map.put(state.subs, id, {event_type, to})}
      send_transport(state, %{id: id, type: "subscribe_events", event_type: event_type})
      {:reply, id, state}
    else
      {:reply, {:error, {:not_connected, state.status}}, state}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    send_transport(state, %{id: ref, type: "unsubscribe_events"})
    {:reply, :ok, %{state | subs: Map.delete(state.subs, ref)}}
  end

  @impl true
  def handle_info({:ha_transport, :connected}, state) do
    send_transport(state, %{type: "auth", access_token: state.token})
    {:noreply, %{state | status: :authenticating}}
  end

  def handle_info({:ha_transport, :text, data}, state) do
    {:noreply, route_frame(data, state)}
  end

  def handle_info({:ha_transport, :closed, _reason}, state) do
    for from <- Map.values(state.pending), do: GenServer.reply(from, {:error, :disconnected})

    state = %{state | transport: nil, status: :disconnected, pending: %{}}
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info(:ha_reconnect, state) do
    {:noreply, ensure_transport(state)}
  end

  # ---- Internals ----

  defp ensure_transport(state) do
    case state.transport_mod.start_link(owner: self(), url: state.url, token: state.token) do
      {:ok, pid} ->
        %{state | transport: pid, status: :connecting}

      {:error, reason} ->
        Logger.warning("HA transport failed to connect: #{inspect(reason)}; retrying")
        %{state | transport: nil, status: :disconnected}
        |> schedule_reconnect()
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :ha_reconnect, state.reconnect_delay)
    state
  end

  defp send_transport(%{transport: nil}, _msg), do: :ok

  defp send_transport(%{transport: transport}, msg) do
    GenServer.cast(transport, {:ha_send, Jason.encode!(msg)})
    :ok
  end

  defp route_frame(data, state) do
    case Jason.decode(data) do
      {:ok, msg} -> route(msg, state)
      {:error, _} -> state
    end
  end

  defp route(msg, state) do
    case Map.get(msg, "type") do
      "auth_ok" -> resubscribe(%{state | status: :connected})

      "auth_invalid" ->
        Logger.error("Home Assistant rejected the access token (auth_invalid); not reconnecting")
        # Do not auto-reconnect: the same token will keep failing.
        %{state | status: :disconnected, transport: stop_transport(state.transport)}

      "result" ->
        reply_to_pending(msg, state)

      "event" ->
        deliver_event(msg, state)

      _ ->
        state
    end
  end

  defp reply_to_pending(msg, state) do
    case Map.pop(state.pending, Map.get(msg, "id")) do
      {nil, _} ->
        state

      {from, rest} ->
        GenServer.reply(from, result_reply(msg))
        %{state | pending: rest}
    end
  end

  defp result_reply(%{"success" => true} = msg), do: Map.get(msg, "result")

  defp result_reply(msg) do
    err = Map.get(msg, "error") || %{}
    {:error, %{code: Map.get(err, "code"), message: Map.get(err, "message")}}
  end

  defp deliver_event(msg, state) do
    case Map.get(state.subs, Map.get(msg, "id")) do
      nil ->
        state

      {_event_type, to} ->
        send(to, {:ha_event, Map.get(msg, "id"), Map.get(msg, "event")})
        state
    end
  end

  defp resubscribe(state) do
    for {id, {event_type, _to}} <- state.subs do
      send_transport(state, %{id: id, type: "subscribe_events", event_type: event_type})
    end

    state
  end

  defp stop_transport(nil), do: nil
  defp stop_transport(pid), do: (GenServer.stop(pid, :normal); nil)
end
