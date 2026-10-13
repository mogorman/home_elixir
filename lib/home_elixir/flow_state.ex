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

    Backed by a Mnesia table — on disk by default (survives restarts; needs the
    app to run as a named node), in-memory when `:flow_state_disc` is false or
    the node is nonode@nohost — so state survives flow reloads and restarts.
    Started by `HomeElixir.Application`.

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
  # Mnesia must not be running when this runs: a running (RAM-schema) Mnesia
  # blocks create_schema, which only writes a fallback file that the following
  # start() recovers as a proper disc schema. On a fresh install (OTP 28.5+ no
  # longer creates the schema on disc at startup) we create it first. The schema
  # dir defaults to priv/mnesia (override with `config :mnesia, dir: <charlist>`).
  # disc_copies need a *named* node, so disk silently falls back to RAM on
  # nonode@nohost (mix's default, tests).
  def start do
    ensure_mnesia_code()

    # Only in disc mode — pointing the dir at a real location makes Mnesia try
    # a disc schema even on nonode@nohost, which leaves it half-started.
    # Charlist, not binary: Mnesia's lists:concat rejects binaries.
    if disc?() do
      Application.put_env(:mnesia, :dir, mnesia_dir())
    end

    if disc?() and not schema_on_disc?() do
      case :mnesia.create_schema([node()]) do
        :ok -> :ok
        {:error, reason} -> raise "FlowState: mnesia create_schema failed: #{inspect(reason)}"
      end
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

  # Mnesia is not a managed app (it must not auto-start before this runs), so
  # its ebin isn't on the code path yet — locate it under the ERTS root and add
  # it.
  defp ensure_mnesia_code do
    if Code.ensure_loaded(:mnesia) == {:module, :mnesia} do
      :ok
    else
      ebin =
        Path.wildcard(Path.join(to_string(:code.root_dir()), "lib/mnesia-*/ebin"))
        |> List.first()

      ebin || raise("FlowState: cannot locate mnesia ebin under #{:code.root_dir()}")
      Code.prepend_path(ebin)
      Code.ensure_loaded!(:mnesia)
    end
  end

  # A disc schema leaves a disc log for the schema table in the Mnesia dir.
  defp schema_on_disc? do
    File.exists?(Path.join(mnesia_dir(), "LATEST.LOG"))
  end

  defp mnesia_dir do
    (Application.get_env(:mnesia, :dir) || Path.expand("priv/mnesia"))
    |> to_string()
    |> Path.expand()
    |> String.to_charlist()
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

  # ---- app metadata (not namespaced to a flow) ----

  # The loaded-flow set lives under a reserved key that can't be a flow module.
  # `loaded_names/0` returns nil when nothing has ever been saved (so an empty
  # set is distinguishable from "first run").
  @meta_flow :__home_elixir_meta__

  def loaded_names do
    tx(fn -> Map.get(read_data(@meta_flow), :loaded) end)
  end

  def save_loaded_names(names) do
    tx(fn -> :mnesia.write({@table, @meta_flow, %{loaded: Enum.uniq(names)}}) end)
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
