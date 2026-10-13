defmodule HomeElixir.WebUI do
  @moduledoc false
  # Cowboy web-socket endpoint for live UI updates. On connect it subscribes to the
  # UI.Hub; each broadcast is forwarded to the browser as a JSON text frame. The
  # browser sends nothing (it only receives pushes).
  @behaviour :cowboy_websocket

  # Required by the behaviour; this Cowboy build drives websocket_init/1.
  def init(_req, state), do: {:ok, state}

  def websocket_init(state) do
    HomeElixir.UI.Hub.subscribe(self())
    {:ok, state}
  end

  # Browser -> server: no input expected.
  def websocket_handle(_payload, state), do: {:ok, state}

  # Hub -> client: forward the pre-encoded, type-tagged JSON.
  def websocket_info({:ui_push, json}, state), do: {:reply, {:text, json}, state}
  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, _state), do: :ok
end
