defmodule HomeElixir.Nodes.Service do
  @moduledoc """
  Sink node: calls a Home Assistant service when a message arrives.

  Config:
    * `domain` — e.g. `"light"` (required)
    * `service` — e.g. `"turn_on"` (required)
    * `data` — optional static `service_data` map; a map `payload` on the
      incoming message is merged in (message wins)

   The call is sent and its ack awaited, ensuring the service is reliably
   delivered over the WebSocket (a fire-and-forget cast proved lossy).
   """
  @behaviour HomeElixir.Node

  alias HomeElixir.HA

  @impl true
  def init(config) do
    %{
      domain: Map.fetch!(config, :domain),
      service: Map.fetch!(config, :service),
      data: Map.new(config[:data] || %{})
    }
  end

  @impl true
  def handle(%{payload: payload}, state) do
    extra = if is_map(payload), do: Map.new(payload), else: %{}
    service_data = Map.merge(state.data, extra)

    case HA.client() do
      nil ->
        :ok

      client ->
        HA.Client.call(client, "call_service", %{
          domain: state.domain,
          service: state.service,
          service_data: service_data
        })
    end

    {[nil], state}
  end
end
