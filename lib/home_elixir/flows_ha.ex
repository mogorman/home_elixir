defmodule HomeElixir.FlowsHA do
  @moduledoc """
  Exposes every flow as a switch in a single "Flows" device in Home Assistant,
  via the Node-RED Companion integration. Each switch's state is the flow's
  loaded state; toggling it in HA loads/unloads the flow.

  On every sync (at boot, after any create/delete/archive/restore, and on a
  timer) the Flows device is reconciled against the live flow set: HA entities
  with no matching non-archived flow are removed, and switches for current flows
  are (re)discovered. The device's current switches are read from HA's REST
  `/api/states` (the reliable source — the WS `get_states` list does not return
  these entities), so orphaned entities are cleaned up even if they predate this
  process's memory of them.

  A no-op when HA is not configured.
  """

  use GenServer

  alias HomeElixir.{FlowStore, HA, Nodered}

  @server_id "home_elixir"
  @device_id "home_elixir_flows"
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
    state = %{switches: %{}, by_id: %{}}
    state = ensure_discovered(state)
    Process.send_after(self(), :sync, 500)
    {:ok, state}
  end

  @impl true
  # Periodic: reconcile the switch set against the live flows (removing stale
  # entities and self-healing switch state after a WS reconnect), then reschedule.
  def handle_info(:sync, state) do
    state = do_sync(state)
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

  def handle_info(_other, state), do: {:noreply, state}

  # ---- internals ----

  # Keep the switch set in step with the flow files, then push their states.
  defp do_sync(state), do: state |> ensure_discovered() |> push_states()

  # Rebuild the switch set from the current flow files: discover new ones, remove
  # the HA entity for every published flow that is now gone (deleted or archived),
  # and refresh each switch's state to the flow's *current* loaded state. The
  # reduce starts from an empty map (not `state.switches`) so a dropped flow's
  # switch is dropped; existing entries are reused by node_id so a sync never
  # re-discovers (and re-ids) a still-present flow.
  defp ensure_discovered(state) do
    client = HA.client()
    # Archived flows get no switch (their entity is removed below); restoring
    # re-creates it.
    flows = FlowStore.list() |> Enum.reject(& &1.archived)
    desired = MapSet.new(flows, fn f -> node_id(f.name) end)

    # Remove HA switches for flows that no longer exist: read the Flows device's
    # current entities from HA (REST) and drop any with no matching flow. Reading
    # the real device (not our memory) also catches orphans that predate this run.
    if connected?(client) do
      case device_switch_ids() do
        {:ok, actual} -> Enum.each(MapSet.difference(actual, desired), &remove_switch/1)
        :error -> :ok
      end
    end

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

  # The node_ids currently on the Flows device. `nil` in the test env seam
  # (`:flows_ha_device_ids`) reads HA's REST `/api/states` — the reliable source
  # for the device's entities (the WS `get_states` list does not return them); a
  # list short-circuits to that set, so tests never touch a real HA. `:error` when
  # HA REST is unreachable or misconfigured, so the caller removes nothing rather
  # than acting on a partial view.
  defp device_switch_ids do
    case Application.get_env(:home_elixir, :flows_ha_device_ids) do
      nil ->
        rest_device_switch_ids()

      ids when is_list(ids) ->
        {:ok, MapSet.new(ids)}
    end
  end

  # Read the device's entities from HA's REST `/api/states` (the reliable source
  # for the device's entities — the WS `get_states` list does not return them),
  # over Mint (the core's HTTP client; the HA WS transport is Mint too). Returns
  # `{:ok, node_ids}` on a 200, `:error` otherwise (transport failure, non-200,
  # misconfig) so the caller removes nothing rather than acting on a partial view.
  defp rest_device_switch_ids do
    base = HA.rest_base()
    token = HA.token()

    if is_binary(base) and is_binary(token) do
      with {scheme, host, port} <- parse_rest(base),
           {:ok, 200, body} <-
             http_get(scheme, host, port, "/api/states", [
               {"authorization", "Bearer " <> token}
             ]),
           {:ok, states} <- Jason.decode(body) do
        if is_list(states), do: {:ok, flow_switch_ids(states)}, else: :error
      else
        _ -> :error
      end
    else
      :error
    end
  end

  # Derive the connect target (`scheme, host, port`) from a REST base URL.
  defp parse_rest(base) do
    uri = URI.parse(base)
    https? = uri.scheme == "https"
    {if(https?, do: :https, else: :http), uri.host, uri.port || if(https?, do: 443, else: 80)}
  end

  # A single HTTP GET: connect, request, then read until Mint reports `:done`.
  # Returns `{:ok, status, body}` or `{:error, reason}`. Mint's socket is
  # `active: :once`, so response bytes arrive as messages (same pattern as the
  # WS transport's handshake).
  defp http_get(scheme, host, port, path, headers) do
    try do
      with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, protocols: [:http1]),
           {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, headers, "") do
        read_response(conn, ref, {nil, <<>>})
      else
        {:error, _conn, reason} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ -> {:error, :http_error}
    catch
      _kind, _reason -> {:error, :http_error}
    end
  end

  defp read_response(conn, ref, {status, body}) do
    receive do
      {:ssl, _r, _d} = msg -> step_response(conn, ref, msg, {status, body})
      {:tcp, _r, _d} = msg -> step_response(conn, ref, msg, {status, body})
      {:ssl_closed, _} -> {:error, :closed}
      {:tcp_closed, _} -> {:error, :closed}
      {:ssl_error, _r, reason} -> {:error, reason}
      {:tcp_error, _r, reason} -> {:error, reason}
    after
      8_000 -> {:error, :timeout}
    end
  end

  defp step_response(conn, ref, msg, {status, body}) do
    case Mint.HTTP.stream(conn, msg) do
      {:ok, conn, responses} ->
        {status, body, done?} =
          Enum.reduce(responses, {status, body, false}, fn
            {:status, ^ref, code}, {_, b, _} -> {code, b, false}
            {:data, ^ref, chunk}, {s, b, _} -> {s, b <> chunk, false}
            {:done, ^ref}, {s, b, _} -> {s, b, true}
            _other, acc -> acc
          end)

        if done?, do: {:ok, status, body}, else: read_response(conn, ref, {status, body})

      {:error, _conn, reason, _responses} ->
        {:error, reason}

      :unknown ->
        read_response(conn, ref, {status, body})
    end
  end

  @doc """
  Pure: the Flows-device switch node_ids present in a `/api/states` list. HA names
  them `switch.flows_<node_id>`, so the node_id is the suffix after that prefix;
  any other entity (other devices, other domains) is ignored.
  """
  def flow_switch_ids(states) do
    states
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["entity_id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&String.starts_with?(&1, "switch.flows_"))
    |> Enum.map(&String.replace_prefix(&1, "switch.flows_", ""))
    |> MapSet.new()
  end

  # Remove a switch from HA in a detached, fully-caught process so a removal never
  # blocks the sync on HA's round-trip (same pattern as fire_entity/2).
  # Nodered.remove no-ops when HA is absent.
  defp remove_switch(node_id) do
    spawn(fn ->
      try do
        Nodered.remove(@server_id, node_id)
      catch
        _kind, _reason -> :ok
      end
    end)

    :ok
  end

  # Push every switch's state to HA (no-op unless connected).
  defp push_states(state) do
    if connected?(HA.client()) do
      for {node_id, sw} <- state.switches, do: fire_entity(sw.state, node_id)
    end

    state
  end

  defp connected?(client), do: is_pid(client) and HA.Client.status(client) == :connected

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

  defp build_discovery(node_id, name) do
    %{
      "type" => "nodered/discovery",
      "component" => "switch",
      "server_id" => @server_id,
      "node_id" => node_id,
      "config" => %{"name" => name, "icon" => "mdi:robot"},
      # No `state` here: it is set exclusively via `nodered/entity` (push_states/1),
      # so a re-discovery can never pin an entity to a stale loaded state.
      "device_info" => %{"id" => @device_id, "name" => "Flows", "manufacturer" => "home-elixir"}
    }
  end

  # Normalize a toggled switch value to a boolean; nil if not a recognized toggle.
  defp toggle_state(%{"type" => "event", "event" => %{"type" => "state_changed", "state" => s}}) do
    s in ["on", true, 1, "1"]
  end

  defp toggle_state(_), do: nil
end
