defmodule HomeElixir.HA do
  @moduledoc """
  Access to the shared, named `HomeElixir.HA.Client`.

  Home Assistant uses a single WebSocket connection shared by every HA-aware
  node (mirroring Node-RED). The app starts one named client when
  `HA_URL`/`HA_TOKEN` are configured; nodes reach it through this module.
  """

  @client_name :home_elixir_ha_client

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
end
