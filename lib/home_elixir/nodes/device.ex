defmodule HomeElixir.Nodes.Device do
  @moduledoc """
  Presents a device (entity) to Home Assistant via the Node-RED integration and
  owns its state bidirectionally.

  On load it registers the device with HA (`nodered/discovery`) and keeps a
  channel on that message id. When the entity is toggled in the HA frontend, HA
  pushes a frame back on that id; this node echoes the state back so the entity
  sticks, then emits it into the flow (source). When a message arrives (e.g. from
  a web button), it sets the entity's state via `nodered/entity` (sink). The node
  also tracks its current state, so a `ui: %{type: "state"}` element can display it.

  Config:
    * `server_id`, `node_id` — identify the device (required, unique per device)
    * `component` — `"switch"` (also `sensor`/`button`/`binary_sensor`), default `"switch"`
    * `config` — entity display: `name`, `icon`, `device_class`, ...
    * `device_info` — device grouping: `id`, `name`, `manufacturer`, ...
    * `state` — initial state; also the reset-to-default target
    * `inherit` — `true` to adopt the entity's current HA state on load (default `false`)

  Inbound messages set the state from `payload` (a bare value, or a map with a
  `"state"`/`:state` key). A `payload` of `%{reset: true}` (or `{:reset, _}`)
  resets to the flow-declared `state`.

  Use `HomeElixir.Nodered.remove/2` to force-delete the entity.
  """
  @behaviour HomeElixir.Node

  alias HomeElixir.{HA, Msg}

  @impl true
  def init(config) do
    state = %{
      server_id: Map.fetch!(config, :server_id),
      node_id: Map.fetch!(config, :node_id),
      state: Map.get(config, :state),
      default_state: Map.get(config, :state),
      inherit: Map.get(config, :inherit, false),
      name: Map.get(Map.get(config, :config) || %{}, :name)
    }

    case HA.client() do
      nil ->
        state

      client ->
        HA.Client.discover(client, build_discovery(config), self())
        if state.inherit, do: spawn_inherit(client, state)
        state
    end
  end

  @impl true
  def handle(%Msg{payload: payload}, state) do
    new = if reset?(payload), do: state.default_state, else: extract_state(payload)

    case HA.client() do
      nil ->
        :ok

      client ->
        HA.Client.call(client, "nodered/entity", %{
          server_id: state.server_id,
          node_id: state.node_id,
          state: new
        })
    end

    {[nil], Map.put(state, :state, new)}
  end

  @impl true
  # HA pushes a frontend/service toggle as an event frame on the discovery's id:
  #   %{"type" => "event", "event" => %{"type" => "state_changed", "state" => s}}
  # Such toggles only notify the flow — they don't change the entity's own state,
  # which is set exclusively via `nodered/entity`. Echo the state back (non-blocking)
  # so the entity sticks, then emit it into the flow.
  def trigger(
        {:ha_channel, _id, %{"type" => "event", "event" => %{"type" => "state_changed", "state" => s}}},
        state
      ) do
    echo_entity(state, s)

    msg = %Msg{
      payload: s,
      topic: state.node_id,
      data: %{server_id: state.server_id, node_id: state.node_id}
    }

    {[msg], Map.put(state, :state, s)}
  end

  # Inherited initial state (see `inherit`); internal only, not emitted to the flow.
  def trigger({:he_device_inherit, s}, state), do: {[nil], Map.put(state, :state, s)}

  def trigger(_other, state), do: {[nil], state}

  # ---- internals ----

  defp reset?(payload) do
    is_map(payload) and not is_nil(Map.get(payload, :reset) || Map.get(payload, "reset"))
  end

  # Push the state to HA in a detached, fully-caught process so the flow's emit
  # (and this node) is never blocked on HA's ack.
  defp echo_entity(state, s) do
    case HA.client() do
      nil ->
        :ok

      client ->
        spawn(fn ->
          try do
            HA.Client.call(client, "nodered/entity", %{
              server_id: state.server_id,
              node_id: state.node_id,
              state: s
            })
          catch
            _kind, _reason -> :ok
          end
        end)
    end
  end

  defp extract_state(payload) do
    cond do
      is_map(payload) and Map.has_key?(payload, "state") -> payload["state"]
      is_map(payload) and Map.has_key?(payload, :state) -> payload[:state]
      true -> payload
    end
  end

  # Marker attribute used to locate this (auto-named) entity in `get_states`.
  defp marker(config), do: Map.fetch!(config, :server_id) <> "/" <> Map.fetch!(config, :node_id)

  defp build_discovery(config) do
    inherit? = Map.get(config, :inherit, false)
    attrs = if inherit?, do: Map.put(Map.get(config, :attributes) || %{}, "__he", marker(config)), else: Map.get(config, :attributes) || %{}

    %{
      "type" => "nodered/discovery",
      "component" => Map.get(config, :component, "switch"),
      "server_id" => Map.fetch!(config, :server_id),
      "node_id" => Map.fetch!(config, :node_id),
      "config" => Map.get(config, :config) || %{},
      "state" => Map.get(config, :state),
      "attributes" => attrs,
      "device_info" => Map.get(config, :device_info)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Polls HA for the entity's current state (matched on the `__he` marker) and
  # pushes it to this node as `{:he_device_inherit, state}`. Runs in a linked,
  # fully-caught task so a failure can never take the node down.
  defp spawn_inherit(client, state) do
    m = marker(%{server_id: state.server_id, node_id: state.node_id})
    parent = self()

    Task.async(fn ->
      try do
        case poll_state(client, m, state.name) do
          {:ok, s} -> send(parent, {:he_device_inherit, s})
          :not_found -> :ok
        end
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp poll_state(client, m, name, tries \\ 6) do
    case fetch_state(client, m, name) do
      {:ok, s} ->
        {:ok, s}

      :not_found when tries > 0 ->
        Process.sleep(250)
        poll_state(client, m, name, tries - 1)

      :not_found ->
        :not_found
    end
  end

  # Match on the precise `__he` marker, falling back to our (controlled)
  # friendly_name for entities created before the marker existed.
  defp fetch_state(client, m, name) do
    case HA.Client.call(client, "get_states") do
      states when is_list(states) ->
        case Enum.find(states, fn s ->
               attrs = Map.get(s, "attributes", %{})
               Map.get(attrs, "__he") == m or (name && Map.get(attrs, "friendly_name") == name)
             end) do
          nil -> :not_found
          %{"state" => s} -> {:ok, s}
        end

      _ ->
        :not_found
    end
  end
end
