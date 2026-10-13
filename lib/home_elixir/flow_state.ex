defmodule HomeElixir.FlowState do
  @moduledoc """
  Persistent per-flow state, namespaced by the calling flow's module.

  Call these from a flow's `handle/1`, a node transform, or `setup/0` — no module
  argument needed. The current flow is taken from the ambient context (the node
  process running the code), so two flows using the same key can't stomp on each
  other's state:

       HomeElixir.FlowState.update(:count, &(&1 + 1))
       HomeElixir.FlowState.get(:last_entity)
       HomeElixir.FlowState.delete(:last_entity)

   Backed by a Mnesia table — in-memory by default, or on disk when
   `:flow_state_disc` is true (disk needs the app to run as a named node) — so
   state survives flow reloads. Started by `HomeElixir.Application`.

  From outside a node (tests, scripts), target a flow explicitly with `as/2`:

      HomeElixir.FlowState.as(MyFlow, fn -> HomeElixir.FlowState.get(:count) end)
  """

  # One record per flow: {table, flow, %{key => value}}. The flow is the primary
  # key (Mnesia's default keypos); the record value is the flow's key->value map.
  # ponytail: one map per flow, so two concurrent writes to different keys of the
  # same flow can drop one update (last writer wins). Fine at home-automation
  # cadence; split to per-key records if two nodes ever contend on a flow's state.
  @table :home_elixir_flow_state
  @flow_pid_key :home_elixir_flow

  # Start Mnesia and ensure the table exists. Idempotent — safe at boot and in tests.
  # ram_copies is Mnesia's default, so for RAM we omit the option. disc_copies needs
  # a *named* node; nonode@nohost (mix's default) rejects it, so disk only works when
  # the app runs as a named node.
  def start do
    # Point the Mnesia schema at a known dir before starting (disk mode only).
    if disc?() do
      Application.put_env(
        :mnesia,
        :dir,
        Application.get_env(:home_elixir, :flow_state_dir, "priv/mnesia")
      )
    end

    :mnesia.start()

    opts =
      if disc?() do
        [{:disc_copies, [node()]}, attributes: [:flow, :data]]
      else
        [attributes: [:flow, :data]]
      end

    case :mnesia.create_table(@table, opts) do
      {:atomic, _} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
      {:aborted, reason} -> raise "FlowState: mnesia create_table failed: #{inspect(reason)}"
    end
  end

  # Set the ambient flow for this process (used by the node engine on init).
  # Prefer `as/2` for scoped, user-facing use.
  def set_flow(flow), do: Process.put(@flow_pid_key, flow)

  # Run `fun` with the ambient flow set to `flow`, restoring the previous value after.
  def as(flow, fun) do
    prev = Process.get(@flow_pid_key)
    Process.put(@flow_pid_key, flow)

    try do
      fun.()
    after
      if prev, do: Process.put(@flow_pid_key, prev), else: Process.delete(@flow_pid_key)
    end
  end

  def get(key, default \\ nil) do
    flow = flow!()
    tx(fn -> Map.get(read_data(flow), key, default) end)
  end

  def put(key, value) do
    flow = flow!()
    tx(fn -> :mnesia.write({@table, flow, Map.put(read_data(flow), key, value)}) end)
  end

  def update(key, fun, default \\ nil) do
    flow = flow!()

    tx(fn ->
      data = read_data(flow)
      result = fun.(Map.get(data, key, default))
      :mnesia.write({@table, flow, Map.put(data, key, result)})
      result
    end)
  end

  # Remove a key; subsequent reads fall back to their default. A no-op if absent.
  def delete(key) do
    flow = flow!()
    tx(fn -> :mnesia.write({@table, flow, Map.delete(read_data(flow), key)}) end)
  end

  # Run `fun` in a Mnesia transaction; unwrap {atomic, result}, re-raise on abort.
  defp tx(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "FlowState: transaction aborted: #{inspect(reason)}"
    end
  end

  # Read the flow's key->value map, or %{} if the flow has no state yet.
  defp read_data(flow) do
    case :mnesia.match_object({@table, flow, :_}) do
      [{@table, ^flow, data}] -> data
      _ -> %{}
    end
  end

  # The current flow, from the ambient context set by the running node or `as/2`.
  defp flow! do
    Process.get(@flow_pid_key) ||
      raise(
        "FlowState called outside a flow context; wrap the call in " <>
          "HomeElixir.FlowState.as(MyFlow, fn -> ... end)"
      )
  end

  # Disk only works on a named node; nonode@nohost (mix's default) can't hold
  # disc_copies tables, so fall back to RAM there.
  defp disc? do
    Application.get_env(:home_elixir, :flow_state_disc, false) and node() != :nonode@nohost
  end
end
