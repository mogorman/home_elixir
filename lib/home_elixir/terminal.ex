defmodule HomeElixir.Terminal do
  @moduledoc """
  Cowboy WebSocket handler that spawns a real shell (default `iex -S mix`,
  i.e. a full app instance + genuine IEx) and bridges it to the browser over
  xterm.js. `stdbuf` forces line-buffered output so IEx streams over the port;
  `HOME_ELIXIR_NO_WEB=1` keeps the spawned instance off the parent's web port.
  """

  @behaviour :cowboy_websocket

  # Required by the behaviour; this Cowboy build drives websocket_init/1 to
  # start the handler.
  def init(_req, state), do: {:ok, state}

  def websocket_init(state) do
    cmd = Map.get(state, :cmd, "iex -S mix")
    port = Port.open({:spawn, "stdbuf -oL -eL " <> cmd}, [:stream, :binary, :exit_status, {:env, env()}])
    {:ok, Map.put(state, :port, port)}
  end

  defp env do
    System.get_env()
    |> Map.put("HOME_ELIXIR_NO_WEB", "1")
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  def websocket_handle({:text, input}, %{port: port} = state) do
    Port.command(port, input)
    {:ok, state}
  end

  def websocket_handle({:binary, input}, %{port: port} = state) do
    Port.command(port, input)
    {:ok, state}
  end

  def websocket_info({port, {:data, out}}, %{port: port} = state) do
    {:reply, {:binary, out}, state}
  end

  def websocket_info({port, :close}, %{port: port} = state) do
    {:stop, :normal, state}
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
