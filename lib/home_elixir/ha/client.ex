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
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
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
  Send a request and ignore its response (fire-and-forget).

  Use for `call_service` and similar, where the caller does not need HA's ack.
  Returns `:ok` (the request is dropped if not connected).
  """
  def fire(client, type, payload \\ %{}) do
    GenServer.cast(client, {:fire, type, Map.new(payload || %{})})
    :ok
  end

  @doc """
  Subscribe to Home Assistant events. Matching events are sent to `to` as
  `{:ha_event, ref, event}`. Returns the subscription `ref`.

  The subscription is registered immediately; if not yet connected it is sent
  automatically on (re)connect, so callers need not wait for a connection.
  """
  def subscribe_events(client, event_type, to, timeout \\ 5_000) do
    GenServer.call(client, {:subscribe_events, event_type, to}, timeout)
  end

  @doc """
  Register a message-id channel for a long-lived HA feature (e.g. a Node-RED
  device). A fresh id from the shared monotonically-increasing counter (the same
  one `call/3` uses, so HA's "ids must increase" rule holds) is injected into
  `discovery_frame`'s `"id"`; frames arriving with that id are forwarded to `to`
  as `{:ha_channel, id, frame}`. The frame is sent now if connected and re-sent
  on every (re)connect, so the entity re-establishes after a dropped connection.
  """
  def discover(client, discovery_frame, to) do
    GenServer.call(client, {:discover, discovery_frame, to})
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
      subs: %{},
      channels: %{}
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
    id = state.next_id
    state = %{state | next_id: id + 1, subs: Map.put(state.subs, id, {event_type, to})}

    if state.status == :connected do
      send_transport(state, %{id: id, type: "subscribe_events", event_type: event_type})
    end

    # Otherwise it is sent by resubscribe/1 on the next auth_ok.
    {:reply, id, state}
  end

  def handle_call({:discover, discovery_frame, to}, _from, state) do
    id = state.next_id
    frame = Map.put(discovery_frame, "id", id)

    # Store the frame WITHOUT its id so it can be re-sent with a fresh id later
    # (re-discovery on a delayed timer re-binds the entity to the live connection).
    state = %{
      state
      | next_id: id + 1,
        channels: Map.put(state.channels, id, %{to: to, discovery: discovery_frame})
    }

    if state.status == :connected, do: send_transport(state, frame)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:fire, type, payload}, state) do
    if state.status == :connected do
      id = state.next_id
      state = %{state | next_id: id + 1}
      send_transport(state, Map.put(payload, "id", id) |> Map.put("type", type))
    end

    {:noreply, state}
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

  def handle_info(:he_rediscover_all, state) do
    if state.status == :connected do
      {:noreply, rediscover_all(state)}
    else
      {:noreply, state}
    end
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
    case Map.get(state.channels, Map.get(msg, "id")) do
      %{to: to} ->
        send(to, {:ha_channel, Map.get(msg, "id"), msg})
        state

      nil ->
        case Map.get(msg, "type") do
          "auth_ok" ->
            state = resubscribe(%{state | status: :connected})
            # Re-discover shortly after connecting (see rediscover_all/1).
            Process.send_after(self(), :he_rediscover_all, 6_000)
            Process.send_after(self(), :he_rediscover_all, 15_000)
            state

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

    channels =
      state.channels
      |> Map.reject(fn {_id, %{to: to}} -> not Process.alive?(to) end)

    for {id, %{discovery: discovery}} <- channels do
      send_transport(state, Map.put(discovery, "id", id))
    end

    %{state | channels: channels}
  end

  # Re-send every device discovery with a fresh (higher) id. After a restart HA can
  # still treat a previously-killed connection as alive; a one-shot startup
  # discovery can then be undone by that connection's "lost" handler, stranding the
  # entity unavailable and dropping inbound. A delayed re-discovery re-binds it.
  defp rediscover_all(state) do
    Enum.reduce(state.channels, state, fn {old_id, %{to: to, discovery: frame}}, st ->
      id = st.next_id

      st = %{
        st
        | next_id: id + 1,
          channels: Map.put(Map.delete(st.channels, old_id), id, %{to: to, discovery: frame})
      }

      if st.status == :connected, do: send_transport(st, Map.put(frame, "id", id))
      st
    end)
  end

  defp stop_transport(nil), do: nil
  defp stop_transport(pid), do: (GenServer.stop(pid, :normal); nil)
end
