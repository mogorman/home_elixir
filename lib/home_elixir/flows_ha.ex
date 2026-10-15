defmodule HomeElixir.FlowsHA do
  @moduledoc """
  Exposes every flow as a switch in a single "Flows" device in Home Assistant,
  via the Node-RED Companion integration. Each switch's state is the flow's
  loaded state; toggling it in HA loads/unloads the flow. On boot, switches for
  flow files that no longer exist are removed from HA.

  A no-op when HA is not configured.
  """

  use GenServer

  alias HomeElixir.{FlowStore, HA, Nodered}

  @server_id "home_elixir"
  @device_id "home_elixir_flows"
  @marker "flows/"
  @resync_ms 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The switch node_id for a flow name (`/` → `_`, downcased)."
  def node_id(name), do: name |> String.downcase() |> String.replace("/", "_")

  @impl true
  def init(_) do
    HomeElixir.UI.Hub.subscribe(self())
    state = %{switches: %{}, by_id: %{}, cleaned: false}
    state = ensure_discovered(state)
    Process.send_after(self(), :sync, 500)
    {:ok, state}
  end

  @impl true
  # Periodic: resync (self-heals switch state after a WS reconnect) + one-time
  # boot cleanup of stale entities, then reschedule.
  def handle_info(:sync, state) do
    state = do_sync(state)
    state = if state.cleaned, do: state, else: clean_stale(state)
    Process.send_after(self(), :sync, @resync_ms)
    {:noreply, state}
  end

  # Flow set changed (web UI, IEx, restore, ...): resync switches + states.
  def handle_info({:ui_push, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "flow_changed"}} -> {:noreply, do_sync(state)}
      _ -> {:noreply, state}
    end
  end

  # HA pushed a frontend toggle on one of our switch channels.
  def handle_info({:ha_channel, id, frame}, state) do
    want = toggle_state(frame)

    case Map.fetch(state.by_id, id) do
      {:ok, node_id} when is_boolean(want) ->
        handle_toggle(state, node_id, want)

      # by_id may be stale (a reconnect just re-assigned channel ids); re-derive
      # and retry once before dropping the toggle.
      _ ->
        state = refresh_by_id(state)

        case Map.fetch(state.by_id, id) do
          {:ok, node_id} when is_boolean(want) -> handle_toggle(state, node_id, want)
          _ -> {:noreply, state}
        end
    end
  end

  # Boot cleanup finished (see clean_stale/1).
  def handle_info(:flows_cleaned, state), do: {:noreply, %{state | cleaned: true}}

  def handle_info(_other, state), do: {:noreply, state}

  # ---- internals ----

  # Keep the switch set in step with the flow files, then push their states.
  defp do_sync(state), do: state |> ensure_discovered() |> push_states()

  # Rebuild the switch set from the current flow files: discover new ones, drop
  # the ones that are gone (deleted or archived — removing their HA entity), and
  # refresh each switch's state to the flow's *current* loaded state. The reduce
  # starts from an empty map (not `state.switches`) so flows no longer present are
  # actually dropped; existing entries are reused by node_id so a sync never
  # re-discovers (and re-ids) a still-present flow.
  defp ensure_discovered(state) do
    client = HA.client()
    # Archived flows get no switch (their entity is dropped below); restoring
    # re-creates it.
    flows = FlowStore.list() |> Enum.reject(& &1.archived)

    switches =
      Enum.reduce(flows, %{}, fn flow, acc ->
        node_id = node_id(flow.name)

        entry =
          case Map.fetch(state.switches, node_id) do
            {:ok, prev} ->
              Map.put(prev, :state, flow.loaded)

            :error ->
              discover_switch(client, node_id, flow.name)
              %{name: flow.name, state: flow.loaded}
          end

        Map.put(acc, node_id, entry)
      end)

    for {old_node_id, _} <- state.switches, not Map.has_key?(switches, old_node_id) do
      remove_switch(old_node_id)
    end

    %{state | switches: switches} |> refresh_by_id()
  end

  # Register a discovery for a not-yet-seen flow (no-op when HA is absent). The
  # channel id is not stored here: it changes on every reconnect's re-discovery,
  # so it is re-derived from HA.Client on demand (see refresh_by_id/1).
  defp discover_switch(nil, _node_id, _name), do: :ok

  defp discover_switch(client, node_id, name) do
    HA.Client.discover(client, build_discovery(node_id, name), self())
    :ok
  end

  # Map the *current* HA channel ids to flow node_ids, from HA.Client's live
  # channels (kept only for our current switches). Reconnects reassign ids, so
  # this must be re-derived rather than cached.
  defp refresh_by_id(state) do
    by_id =
      case HA.client() do
        pid when is_pid(pid) ->
          HA.Client.channels_for(pid, self())
          |> Enum.filter(fn {_id, node_id} -> Map.has_key?(state.switches, node_id) end)
          |> Map.new()

        _ ->
          %{}
      end

    %{state | by_id: by_id}
  end

  # Nodered.remove no-ops when HA is not connected.
  defp remove_switch(node_id) do
    Nodered.remove(@server_id, node_id)
    :ok
  end

  # Push every switch's state to HA (no-op unless connected).
  defp push_states(state) do
    client = HA.client()

    if is_pid(client) and HA.Client.status(client) == :connected do
      for {node_id, sw} <- state.switches, do: fire_entity(sw.state, node_id)
    end

    state
  end

  defp handle_toggle(state, node_id, want) do
    %{name: name} = state.switches[node_id]

    loaded =
      if want,
        do: FlowStore.load(name) == :ok,
        else:
          (
            FlowStore.unload(name)
            false
          )

    state = put_in(state.switches[node_id].state, loaded)
    fire_entity(loaded, node_id)
    {:noreply, state}
  end

  # Push a switch's state to HA. Uses `call/4` (not `fire/3` or `push/3`) inside a
  # detached, fully-caught process: HA only commits a switch's state change once it
  # has acked the `nodered/entity` frame, and a fire-and-forget push is not acked in
  # time, so the entity reverts. `call/4` also advances the shared id per entity (no
  # duplicate-id rejection). The spawn keeps a sync/toggle from blocking on HA's
  # round-trip (same pattern as Nodes.Device.echo_entity/2).
  defp fire_entity(loaded, node_id) do
    case HA.client() do
      client when is_pid(client) ->
        spawn(fn ->
          try do
            HA.Client.call(client, "nodered/entity", %{
              server_id: @server_id,
              node_id: node_id,
              state: loaded
            })
          catch
            _kind, _reason -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  # One-time (once connected): remove HA entities under our marker whose flow
  # file no longer exists. Runs in a detached task so a slow get_states never
  # blocks toggle handling; retries (leaves `cleaned` false) until it succeeds.
  defp clean_stale(state) do
    client = HA.client()

    if is_pid(client) and HA.Client.status(client) == :connected and not state.cleaned do
      me = self()
      valid = MapSet.new(Map.keys(state.switches))

      spawn(fn ->
        case HA.Client.call(client, "get_states") do
          states when is_list(states) ->
            for s <- states,
                attrs = Map.get(s, "attributes", %{}),
                m = Map.get(attrs, "__he"),
                is_binary(m) and String.starts_with?(m, @marker),
                node_id = marker_node_id(m),
                not MapSet.member?(valid, node_id) do
              Nodered.remove(@server_id, node_id)
            end

            send(me, :flows_cleaned)

          _ ->
            :ok
        end
      end)
    end

    state
  end

  defp build_discovery(node_id, name) do
    %{
      "type" => "nodered/discovery",
      "component" => "switch",
      "server_id" => @server_id,
      "node_id" => node_id,
      "config" => %{"name" => name, "icon" => "mdi:robot"},
      # `__he` marker must land in the entity's `attributes` so clean_stale/1 can
      # find it via `get_states` (same convention as HomeElixir.Nodes.Device).
      # No `state` here: it is set exclusively via `nodered/entity` (push_states/1),
      # so a re-discovery can never pin an entity to a stale loaded state.
      "attributes" => %{"__he" => @marker <> node_id},
      "device_info" => %{"id" => @device_id, "name" => "Flows", "manufacturer" => "home-elixir"}
    }
  end

  # Normalize a toggled switch value to a boolean; nil if not a recognized toggle.
  defp toggle_state(%{"type" => "event", "event" => %{"type" => "state_changed", "state" => s}}) do
    s in ["on", true, 1, "1"]
  end

  defp toggle_state(_), do: nil

  # The node_id embedded in our `__he` marker (`"flows/<node_id>"`).
  defp marker_node_id(m), do: m |> String.split(@marker, parts: 2) |> Enum.at(1)
end
