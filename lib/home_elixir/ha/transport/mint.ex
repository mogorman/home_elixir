defmodule HomeElixir.HA.Transport.Mint do
  @moduledoc """
  WebSocket transport backed by Mint + Mint.WebSocket.

  Implements the transport convention expected by `HomeElixir.HA.Client`:
  started with `start_link/1` (`owner:`, `url:`), reports
  `{:ha_transport, :connected | :text, binary | :closed, reason}` to its owner,
  and sends outbound frames given via `GenServer.cast(transport, {:ha_send, json})`.

  The process owns an active-mode Mint connection, so inbound TCP/SSL data
  arrives here as messages.

  Validated against a live Home Assistant over `wss://` (connect, auth, and a
  `get_states` round-trip). `mix run scripts/ha_validate.exs` reproduces it.
  """

  use GenServer

  @handshake_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner)
    url = Keyword.fetch!(opts, :url)

    with {:ok, t_scheme, ws_scheme, host, port, path} <- parse_url(url),
         {:ok, conn} <- Mint.HTTP.connect(t_scheme, host, port, connect_opts(t_scheme)),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:ok, %{owner: owner, conn: conn, ref: ref, ws: nil}, {:continue, :handshake}}
    else
      {:error, _conn, reason} -> {:stop, {:connect_error, reason}}
      {:error, reason} -> {:stop, {:connect_error, reason}}
    end
  end

  @impl true
  def handle_continue(:handshake, state) do
    case handshake(state.conn, state.ref, @handshake_timeout) do
      {:ok, conn, ws} ->
        send(state.owner, {:ha_transport, :connected})
        {:noreply, %{state | conn: conn, ws: ws}}

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_cast({:ha_send, json}, state), do: {:noreply, do_send(state, [{:text, json}])}

  @impl true
  def handle_info({:tcp, _ref, _data} = msg, state), do: on_data(msg, state)
  def handle_info({:ssl, _ref, _data} = msg, state), do: on_data(msg, state)

  def handle_info({:tcp_closed, _}, state), do: closed(state, :closed)
  def handle_info({:ssl_closed, _}, state), do: closed(state, :closed)
  def handle_info({:tcp_error, _ref, reason}, state), do: closed(state, {:tcp_error, reason})
  def handle_info({:ssl_error, _ref, reason}, state), do: closed(state, {:ssl_error, reason})
  def handle_info(_other, state), do: {:noreply, state}

  # ---- Internals ----

  defp closed(state, reason) do
    send(state.owner, {:ha_transport, :closed, reason})
    {:stop, :normal, state}
  end

  defp handshake(conn, ref, timeout) do
    receive do
      {:tcp, _ref, _d} = msg -> step_handshake(conn, ref, msg)
      {:ssl, _ref, _d} = msg -> step_handshake(conn, ref, msg)
      {:tcp_closed, _} -> {:stop, :closed_during_handshake}
      {:ssl_closed, _} -> {:stop, :closed_during_handshake}
    after
      timeout -> {:stop, :handshake_timeout}
    end
  end

  defp step_handshake(conn, ref, msg) do
    case Mint.WebSocket.stream(conn, msg) do
      :unknown ->
        handshake(conn, ref, @handshake_timeout)

      {:ok, conn, responses} ->
        code = pick(responses, :status)
        headers = pick(responses, :headers)

        if is_integer(code) and is_list(headers) do
          case Mint.WebSocket.new(conn, ref, code, headers) do
            {:ok, conn, ws} -> {:ok, conn, ws}
            {:error, _conn, _reason} -> {:stop, :bad_handshake}
          end
        else
          handshake(conn, ref, @handshake_timeout)
        end

      {:error, _conn, _reason, _responses} ->
        {:stop, :handshake_error}
    end
  end

  defp pick(responses, tag) do
    Enum.find_value(responses, fn
      {^tag, _ref, value} -> value
      _ -> nil
    end)
  end

  defp on_data(msg, state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        data = pick(responses, :data)
        state = %{state | conn: conn}
        if data, do: process_frames(data, state), else: {:noreply, state}

      {:error, _conn, _reason, _responses} ->
        closed(state, :stream_error)
    end
  end

  defp process_frames(data, state) do
    {:ok, ws, frames} = Mint.WebSocket.decode(state.ws, data)
    state = %{state | ws: ws}

    {to_send, closed?} =
      Enum.reduce(frames, {[], false}, fn frame, {acc, closed?} ->
        case frame do
          {:ping, payload} ->
            {[{:pong, payload} | acc], closed?}

          {:text, bin} ->
            send(state.owner, {:ha_transport, :text, bin})
            {acc, closed?}

          :close ->
            send(state.owner, {:ha_transport, :closed, :closed})
            {acc, true}

          _ ->
            {acc, closed?}
        end
      end)

    state = if to_send == [], do: state, else: do_send(state, Enum.reverse(to_send))

    if closed? do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp do_send(state, frames) do
    Enum.reduce(frames, state, fn frame, st ->
      case Mint.WebSocket.encode(st.ws, frame) do
        {:ok, ws, bytes} ->
          {:ok, conn} = Mint.WebSocket.stream_request_body(st.conn, st.ref, bytes)
          %{st | ws: ws, conn: conn}

        {:error, _reason, ws} ->
          %{st | ws: ws}
      end
    end)
  end

  # TLS (wss://) must verify the peer against a CA bundle. A self-contained
  # release doesn't ship OTP's built-in cacerts, so load the system bundle.
  defp connect_opts(:https) do
    [protocols: [:http1], transport_opts: [cacerts: system_cacerts()]]
  end

  defp connect_opts(_), do: [protocols: [:http1]]

  defp system_cacerts do
    case Enum.find(
           [
             "/etc/ssl/certs/ca-certificates.crt",
             "/etc/pki/tls/certs/ca-bundle.crt",
             "/etc/ssl/cert.pem"
           ],
           &File.exists?/1
         ) do
      nil ->
        []

      path ->
        path
        |> File.read!()
        |> :public_key.pem_decode()
        |> Enum.filter(fn {tag, _, _} -> tag == :Certificate end)
        |> Enum.map(fn {_, der, _} -> der end)
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    tls? = uri.scheme in ["wss", "https"]
    port = uri.port || if(tls?, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    host =
      uri.host ||
        raise ArgumentError, "URL #{inspect(url)} is missing a host"

    {:ok, (if tls?, do: :https, else: :http), (if tls?, do: :wss, else: :ws), host, port, path}
  end
end
