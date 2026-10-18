defmodule HomeElixir.HA do
  @moduledoc """
  Access to the shared, named `HomeElixir.HA.Client`.

  Home Assistant uses a single WebSocket connection shared by every HA-aware
  node (mirroring Node-RED). The app starts one named client when
  `HA_URL`/`HA_TOKEN` are configured; nodes reach it through this module.
  """

  @client_name :home_elixir_ha_client
  @snapshot_timeout 15_000

  @doc "The atom name of the shared client process."
  def client_name, do: @client_name

  @doc "The pid of the shared client, or `nil` if it is not running."
  def client, do: GenServer.whereis(@client_name)

  @doc "True when a shared client is running."
  def connected?, do: not is_nil(client())

  @doc "The configured HA endpoint (env `HA_URL` or config `:ha_url`), or `nil`."
  def config_url do
    System.get_env("HA_URL") || Application.get_env(:home_elixir, :ha_url)
  end

  @doc """
  The HA auth token used for all HA API calls (the shared WS client and REST).
  First match wins:

    1. env `SUPERVISOR_TOKEN` — present only when running as an HA add-on; the
       only token the supervisor's Core proxy accepts
    2. the token from the most recent web login (HA OAuth), stored in global
       config
    3. env `HA_TOKEN` (the NixOS module)
    4. config `:ha_token` (e.g. config/secret.exs)

  `nil` when nothing is configured.
  """
  def token do
    System.get_env("SUPERVISOR_TOKEN")
    || HomeElixir.Config.global_config() |> Map.get("ha_token")
    || System.get_env("HA_TOKEN")
    || Application.get_env(:home_elixir, :ha_token)
  end

  @doc "The public web origin (config `:web_base_url`), or `nil`."
  def web_base_url do
    Application.get_env(:home_elixir, :web_base_url)
  end

  @doc """
  The HA REST base URL (`scheme://host[:port][/prefix]`) for HTTP API calls,
  derived from the configured endpoint (which may be a `wss://`/`ws://`
  WebSocket URL). Keeps any proxy path prefix: `ws://supervisor/core/api/websocket`
  becomes `http://supervisor/core`, so callers append `/api/...` as usual.
  `nil` when no HA endpoint is configured.
  """
  def rest_base do
    case config_url() do
      nil ->
        nil

      url ->
        rest_origin(url) <> rest_prefix(url)
    end
  end

  @doc """
  The REST path prefix implied by the configured endpoint (`"/core"` for the
  supervisor Core proxy, `""` for a direct Core URL), or `nil` when no endpoint
  is configured.
  """
  def rest_prefix do
    case config_url() do
      nil ->
        nil

      url ->
        rest_prefix(url)
    end
  end

  @doc """
  Fetch a camera snapshot for `entity_id` as raw bytes, via HA's
  `/api/camera_proxy/{entity}` REST endpoint, over Mint (a core dependency, so
  callers don't need to install `req`). Returns `{:ok, binary}` or
  `{:error, reason}`.
  """
  def snapshot(entity_id) do
    base = rest_base()
    token = token()

    cond do
      is_nil(base) or is_nil(token) ->
        {:error, "Home Assistant is not configured"}

      true ->
        case http_get(base <> "/api/camera_proxy/" <> entity_id, token) do
          {:ok, body} -> {:ok, body}
          {:error, reason} -> {:error, {:snapshot, reason}}
        end
    end
  end

  @doc """
  Fetch a camera snapshot for `entity_id` and return it base64-encoded (for
  inlining as a `data:image/jpeg;base64,...` URL). Built on `snapshot/1`.
  Returns `{:ok, base64}` or `{:error, reason}`.
  """
  def snapshot_b64(entity_id) do
    case snapshot(entity_id) do
      {:ok, bytes} -> {:ok, Base.encode64(bytes)}
      {:error, _} = err -> err
    end
  end

  # A WS path like "/core/api/websocket" means REST lives under "/core/api/...";
  # a direct "/api/websocket" means REST lives under "/api/...".
  defp rest_prefix(url) do
    url
    |> URI.parse()
    |> then(& &1.path)
    |> then(&if is_binary(&1), do: &1, else: "")
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> drop_trailing("websocket")
    |> drop_trailing("api")
    |> then(fn
      [] -> ""
      segs -> "/" <> Enum.join(segs, "/")
    end)
  end

  defp drop_trailing([], _seg), do: []
  defp drop_trailing(list, seg), do: if(List.last(list) == seg, do: Enum.drop(list, -1), else: list)

  defp rest_origin(url) do
    url
    |> String.replace_prefix("wss://", "https://")
    |> String.replace_prefix("ws://", "http://")
    |> URI.parse()
    |> then(fn uri ->
      # URI.parse fills the scheme's default port; only an explicit non-default
      # port belongs in the base.
      default = if uri.scheme == "https", do: 443, else: 80
      port = if uri.port && uri.port != default, do: ":#{uri.port}", else: ""
      "#{uri.scheme}://#{uri.host}#{port}"
    end)
  end

  @doc """
  Store `token` as the shared HA auth (beats the static config until the next
  login) and make sure the shared WS client runs with the current token
  (start it when absent, restart it when it holds a different one). Called on
  a successful web login.
  """
  def activate(token) do
    HomeElixir.Config.put_global(:ha_token, token)
    ensure_client()
    :ok
  end

  @doc "Ensure the shared WS client is running with the current token."
  def ensure_client do
    url = config_url()
    token = token()

    if Application.get_env(:home_elixir, :auto_start_ha, true) && url && token do
      case client() do
        nil ->
          start_client(url, token)

        pid ->
          if HomeElixir.HA.Client.token(pid) != token do
            Supervisor.terminate_child(HomeElixir.Supervisor, pid)
            start_client(url, token)
          end

          :ok
      end
    else
      :ok
    end
  end

  defp start_client(url, token) do
    Supervisor.start_child(
      HomeElixir.Supervisor,
      {HomeElixir.HA.Client, [name: client_name(), url: url, token: token]}
    )
  end

  @doc """
  Resolve who an HA access token belongs to via the WebSocket `auth/current_user`
  command, on a transient one-shot client. Returns `{:ok, {name, is_admin}}` or
  `{:error, reason}`.
  """
  def whoami(token) do
    case config_url() do
      nil ->
        {:error, "Home Assistant is not configured"}

      url ->
        # Run in an unlinked spawn: the transient client is linked to that process,
        # so a failed connect (transport taking the client down) dies there and
        # can never exit the caller. `safe_whoami/2` turns that into a fast error.
        caller = self()
        ref = make_ref()
        spawn(fn -> send(caller, {ref, safe_whoami(url, token)}) end)

        receive do
          {^ref, result} -> result
        after
          8_000 -> {:error, :connect_timeout}
        end
    end
  end

  defp safe_whoami(url, token) do
    try do
      whoami_sync(url, token)
    catch
      :exit, _ -> {:error, :connect_failed}
      _, _ -> {:error, :connect_failed}
    end
  end

  # The transient client is linked to the Task process, so it is torn down when
  # the Task exits (we do not stop it here — it may already be dead on a failed
  # connect, and stopping a dead process would raise).
  defp whoami_sync(url, token) do
    case HomeElixir.HA.Client.start_link(url: url, token: token) do
      {:ok, client} ->
        if wait_connected?(client, 5_000) do
          parse_whoami(HomeElixir.HA.Client.call(client, "auth/current_user", %{}, 5_000))
        else
          {:error, :connect_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Map a `auth/current_user` result to `{name, is_admin}`; pass through errors.
  defp parse_whoami(%{"id" => _id, "name" => name} = result) do
    {:ok, {name, result["is_admin"] == true}}
  end

  defp parse_whoami({:error, _} = err), do: err
  defp parse_whoami(other), do: {:error, {:whoami, other}}

  defp wait_connected?(client, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(client, deadline)
  end

  defp wait_loop(client, deadline) do
    case HomeElixir.HA.Client.status(client) do
      :connected ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(20)
          wait_loop(client, deadline)
        end
    end
  end

  # ---- Camera snapshot over Mint (core HTTP, no `req`) ----

  defp http_get(url, token) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    headers = [{"authorization", "Bearer " <> token}, {"accept", "image/*"}]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port, mint_opts(scheme)),
         {:ok, conn, _ref} <- Mint.HTTP.request(conn, "GET", path, headers, "") do
      read_response(conn, %{status: nil, length: nil, got: 0, body: []})
    end
  end

  # TLS verifies the peer against the system bundle (a self-contained release
  # doesn't ship OTP's built-in cacerts). Same lookup as the WS transport.
  defp mint_opts(:https), do: [protocols: [:http1], transport_opts: [cacerts: system_cacerts()]]
  defp mint_opts(:http), do: [protocols: [:http1]]

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

  # The socket's `{:tcp, ref, data}` ref is set at connect time, not per request,
  # so match any ref and let Mint.HTTP.stream validate it (returns :unknown for
  # a foreign message — same as the WS transport).
  defp read_response(conn, state) do
    receive do
      {:tcp, _ref, _data} = msg -> stream_response(conn, msg, state)
      {:ssl, _ref, _data} = msg -> stream_response(conn, msg, state)
      {:tcp_closed, _} -> {:error, :connection_closed}
      {:ssl_closed, _} -> {:error, :connection_closed}
      {:tcp_error, _ref, reason} -> {:error, {:socket, reason}}
      {:ssl_error, _ref, reason} -> {:error, {:socket, reason}}
    after
      @snapshot_timeout -> {:error, :timeout}
    end
  end

  defp stream_response(conn, msg, state) do
    case Mint.HTTP.stream(conn, msg) do
      :unknown ->
        read_response(conn, state)

      {:ok, conn, []} ->
        read_response(conn, state)

      {:ok, conn, parts} ->
        state = reduce_parts(parts, state)
        if body_complete?(state), do: finish(state), else: read_response(conn, state)

      {:error, _conn, reason, _parts} ->
        {:error, {:http, reason}}
    end
  end

  defp reduce_parts(parts, state) do
    Enum.reduce(parts, state, fn
      {:status, _ref, code}, st -> %{st | status: code}
      {:headers, _ref, headers}, st -> %{st | length: content_length(headers)}
      {:data, _ref, data}, st -> %{st | got: st.got + byte_size(data), body: [data | st.body]}
      _other, st -> st
    end)
  end

  defp content_length(headers) do
    Enum.find_value(headers, fn
      {"content-length", value} -> String.to_integer(value)
      _ -> nil
    end)
  end

  # HA's camera_proxy sends a fixed content-length (never chunked), so the body
  # is complete once that many bytes have arrived.
  defp body_complete?(%{status: status, length: length, got: got}) do
    is_integer(status) and is_integer(length) and got >= length
  end

  defp finish(%{status: 200, body: body}) do
    {:ok, body |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp finish(%{status: code}) do
    {:error, {:status, code}}
  end
end
