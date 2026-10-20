defmodule HomeElixir.Terminal do
  @moduledoc """
  Cowboy WebSocket handler that gives the browser a real IEx bridged over
  xterm.js.

  When the app itself is a named Erlang node (started with `--sname
  home_elixir`, see README) the shell is `iex --remsh home_elixir` — a genuine
  remote connection into this app's VM, with its code path, so `Node.list()`,
  `HomeElixir.FlowStore.list()`, the HA client, etc. all see the live instance
   rather than a second app. `script` runs IEx in a pseudo-terminal so keystrokes
   echo and line editing work over the port.

  If the app is NOT a named node, it falls back to a self-contained
  `iex -S mix` (its own app instance) with `HOME_ELIXIR_NO_WEB=1` so it stays
  off the parent's web port.
  """

  @behaviour :cowboy_websocket

  # An idle websocket is reaped by intermediate idle timeouts; a periodic
  # protocol-level ping (the browser auto-pongs; the frame never reaches the
  # IEx port) keeps the connection alive.
  @keepalive_interval 20_000

  # Required by the behaviour; this Cowboy build drives websocket_init/1 to
  # start the handler.
  def init(_req, state), do: {:ok, state}

  def websocket_init(state) do
    {cmd, env} = spawn_spec()

    # `script` runs the shell in a pseudo-terminal so keystrokes echo and line
    # editing work; its own stdio is a pipe this port reads/writes.
    port =
      Port.open(
        {:spawn, "script -qec \"#{cmd}\" /dev/null"},
        [:stream, :binary, :exit_status, {:env, env}]
      )

    Process.send_after(self(), :ka, @keepalive_interval)
    {:ok, Map.put(state, :port, port)}
  end

  # The app's own distributed node name, or nil when it is not a named node.
  defp app_node do
    case :erlang.node() do
      :nonode@nohost -> nil
      node -> node
    end
  end

  defp spawn_spec do
    # The app runs in a container with no TTY, so its env has no TERM. Without a
    # real terminal type Erlang/IEx disables its line editor — no history
    # (up/down), cursor editing (left/right), or tab completion, and raw escape
    # sequences get echoed. Force one so the in-browser shell edits properly.
    base =
      System.get_env()
      |> Map.put("TERM", "xterm-256color")
      |> Map.put("COLORTERM", "truecolor")

    case app_node() do
      nil ->
        env = base |> Map.put("HOME_ELIXIR_NO_WEB", "1") |> to_env()
        {"iex -S mix", env}

      node ->
        short = node |> Atom.to_string() |> String.split("@") |> hd()
        cookie = Application.get_env(:home_elixir, :node_cookie, "home_elixir")
        # `-pa` must be repeated per dir (a single colon-joined value is ignored).
        pa = :code.get_path() |> Enum.map(&("-pa " <> List.to_string(&1))) |> Enum.join(" ")
        aflags = "-sname #{short}_console -setcookie #{cookie} -remsh #{short} #{pa}"
        env = base |> Map.put("ERL_AFLAGS", aflags) |> to_env()
        {"iex", env}
    end
  end

  defp to_env(map) do
    map |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  def websocket_handle({:text, input}, %{port: port} = state) do
    Port.command(port, input)
    {:ok, state}
  end

  def websocket_handle({:binary, input}, %{port: port} = state) do
    Port.command(port, input)
    {:ok, state}
  end

  # Protocol control frames (the browser's auto-pong to our keepalive ping, etc.)
  # are not terminal input — ignore them.
  def websocket_handle(_frame, state), do: {:ok, state}

  def websocket_info({port, {:data, out}}, %{port: port} = state) do
    {:reply, {:binary, out}, state}
  end

  def websocket_info({port, :close}, %{port: port} = state) do
    {:stop, :normal, state}
  end

  # Keepalive tick: send a ping (browser auto-pongs) and schedule the next one.
  def websocket_info(:ka, state) do
    Process.send_after(self(), :ka, @keepalive_interval)
    {:reply, {:ping, ""}, state}
  end

  def websocket_info({:exit_status, _port, _code}, state), do: {:stop, :normal, state}
  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, %{port: port} = _state) do
    try do
      Port.command(port, "exit()\n")
      :timer.sleep(250)
    rescue
      _ -> :ok
    end

    Port.close(port)
  end

  def terminate(_reason, _req, _state), do: :ok
end
