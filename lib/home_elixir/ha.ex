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

  @doc "The configured HA auth token (env `HA_TOKEN` or config `:ha_token`), or `nil`."
  def token do
    System.get_env("HA_TOKEN") || Application.get_env(:home_elixir, :ha_token)
  end

  @doc "The public web origin (config `:web_base_url`), or `nil`."
  def web_base_url do
    Application.get_env(:home_elixir, :web_base_url)
  end

  @doc """
  The HA REST base URL (`scheme://host[:port]`) for HTTP API calls, derived from
  the configured endpoint (which may be a `wss://`/`ws://` WebSocket URL).
  `nil` when no HA endpoint is configured.
  """
  def rest_base do
    case config_url() do
      nil ->
        nil

      url ->
        url
        |> String.replace_prefix("wss://", "https://")
        |> String.replace_prefix("ws://", "http://")
        |> URI.parse()
        |> then(&"#{&1.scheme}://#{&1.host}#{if &1.port, do: ":#{&1.port}", else: ""}")
    end
  end

  @doc """
  The HA WebSocket endpoint derived from the configured URL (which may be a
  plain `http(s)://` REST base). `nil` when no HA endpoint is configured.
  """
  def ws_url do
    case config_url() do
      nil ->
        nil

      url ->
        url
        |> String.replace_prefix("https://", "wss://")
        |> String.replace_prefix("http://", "ws://")
    end
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
