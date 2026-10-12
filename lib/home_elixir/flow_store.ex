defmodule HomeElixir.FlowStore do
  @moduledoc """
  Discovers flow `.ex` files and loads/unloads them at runtime.

  Flow files live in a directory (default `flows/`, overridable via the
  `:home_elixir, :flows_dir` config). Each file defines one flow module;
  `load/1` compiles the file if needed and starts it via `HomeElixir.Registry`,
  `unload/1` stops it.

  The module atom for each file is taken from the compiler's result and cached,
  since `String.to_atom/1` does not reliably yield a matching atom in all VMs.
  """

  use GenServer

  require Logger

  alias HomeElixir.Registry

  # A load may trigger a one-time external dep build (HomeElixir.Dep.install),
  # which can take well over the default 5s GenServer.call timeout on a cold
  # cache. Subsequent loads are fast (cached), so this only matters the first time.
  @install_timeout 180_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def list, do: call(:list)
  def load(name), do: call({:load, name}, @install_timeout)
  def unload(name), do: call({:unload, name})

  @doc "UI elements declared by loaded flows (name-keyed, for the web UI)."
  def ui, do: call(:ui)

  @doc "Inject a message into a node of a loaded flow (used by web controls)."
  def click(name, node, payload \\ nil), do: call({:click, name, node, payload})

  @doc "Recompile a flow from disk and restart it (or load it if not running)."
  def reload(name), do: call({:reload, name}, @install_timeout)

  @doc "Reload every currently-loaded flow from disk."
  def reload_all, do: call({:reload_all}, @install_timeout)

  @doc "UI elements for one flow (loaded or not), with live `value` when loaded."
  def flow_ui(name), do: call({:flow_ui, name})

  @doc "Drop the cached module atom for a flow so the next load recompiles it."
  def forget(name), do: call({:forget, name})

  @doc "Whether a flow is currently loaded (without compiling it)."
  def loaded?(name), do: call({:loaded?, name})

  @doc """
  Compile a source string and report the result, without loading it into the
  flow set. Runs in this GenServer (a stable process), not the request process.
  """
  def check(source), do: call({:check, source})

  @doc """
  Load the flows that were loaded last run (persisted in `.loaded`). On the very
  first run (no state file) this loads every flow file, establishing the set.
  Flows that fail to load are logged and skipped.
  """
  def restore do
    names = if File.exists?(loaded_file()), do: read_loaded(), else: all_flow_names()

    Enum.each(names, fn name ->
      case load(name) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("could not restore flow #{name}: #{inspect(reason)}")
      end
    end)
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:list, _from, cache) do
    {flows, cache} = list_flows(cache)
    {:reply, flows, cache}
  end

  def handle_call(:ui, _from, cache) do
    {flows, cache} = list_flows(cache)
    name_of = Map.new(flows, fn f -> {f.module, f.name} end)

    elements =
      for %{module: mod, node_id: node_id, ui: ui} <- Registry.ui_elements(),
          name = Map.get(name_of, mod) do
        %{
          name: name,
          node: node_id,
          type: ui.type,
          label: Map.get(ui, :label),
          payload: Map.get(ui, :payload),
          value: if(ui.type == "state", do: node_state_value(mod, node_id), else: nil)
        }
      end

    {:reply, elements, cache}
  end

  def handle_call({:click, name, node, payload}, _from, cache) do
    {reply, cache} =
      case resolve(name) do
        {:ok, path} ->
          {mod, cache} = atom_for(path, cache)

          if Registry.loaded?(mod) do
            Registry.send_msg(mod, node, HomeElixir.Msg.new(payload || %{}, topic: node))
            {:ok, cache}
          else
            {{:error, :not_loaded}, cache}
          end

        error ->
          {error, cache}
      end

    {:reply, reply, cache}
  end

  def handle_call({:forget, name}, _from, cache) do
    {:reply, :ok, Map.delete(cache, name)}
  end

  def handle_call({:loaded?, name}, _from, cache) do
    loaded =
      case Map.fetch(cache, name) do
        {:ok, mod} -> Registry.loaded?(mod)
        :error -> false
      end

    {:reply, loaded, cache}
  end

  def handle_call({:check, source}, _from, cache) do
    tmp = Path.join(System.tmp_dir!(), "flow_check_#{System.unique_integer([:positive])}.ex")
    File.write!(tmp, source)

    result =
      try do
        Code.compile_file(tmp)
        {:ok, "OK — compiles cleanly"}
      rescue
        e -> {:error, Exception.message(e)}
      after
        File.rm(tmp)
      end

    {:reply, result, cache}
  end

  def handle_call({:load, name}, _from, cache) do
    {reply, cache} = do_load(name, cache)
    {:reply, reply, cache}
  end

  def handle_call({:unload, name}, _from, cache) do
    {reply, cache} = do_unload(name, cache)
    {:reply, reply, cache}
  end

  def handle_call({:reload, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)
        cache = if Registry.loaded?(mod), do: elem(do_unload(name, cache), 1), else: cache
        {reply, cache} = do_load(name, cache)
        {:reply, reply, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:reload_all}, _from, cache) do
    cache =
      all_flow_names()
      |> Enum.reduce(cache, fn name, cache ->
        case resolve(name) do
          {:ok, path} ->
            {mod, cache} = atom_for(path, cache)

            if Registry.loaded?(mod) do
              {_, cache} = do_unload(name, cache)
              {_, cache} = do_load(name, cache)
              cache
            else
              cache
            end

          _ ->
            cache
        end
      end)

    {:reply, :ok, cache}
  end

  def handle_call({:flow_ui, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)
        loaded = Registry.loaded?(mod)

        elements =
          for {node_id, {_handler, config}} <- mod.__flow__().nodes,
              %{type: _t} = ui <- [Map.get(config, :ui)] do
            %{
              name: name,
              node: node_id,
              type: ui.type,
              label: Map.get(ui, :label),
              payload: Map.get(ui, :payload),
              value: if(ui.type == "state" and loaded, do: node_state_value(mod, node_id), else: nil)
            }
          end

        {:reply, elements, cache}

      error ->
        {:reply, error, cache}
    end
  end

  # ---- internals ----

  # Load/unload bodies shared by the `load`/`unload`/`reload`/`reload_all` calls.
  defp do_load(name, cache) do
    case resolve(name) do
      {:ok, path} ->
        # Recompile from source so an edited flow is picked up on (re)load.
        reply =
          try do
            mod = compile_atom(path)

            case Registry.load(mod) do
              {:ok, _pid} ->
                Logger.info("loaded flow #{name} (#{inspect(mod)})")
                :ok

              {:error, :already_loaded} ->
                :ok

              {:error, reason} ->
                {:error, reason}
            end
          rescue
            e -> {:error, Exception.message(e)}
          end

        if reply == :ok, do: add_loaded(name)
        {reply, cache}

      error ->
        {error, cache}
    end
  end

  defp do_unload(name, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)
        result = Registry.unload(mod)
        Logger.info("unloaded flow #{name} (#{inspect(result)})")
        if result == :ok, do: remove_loaded(name)
        {result, cache}

      error ->
        {error, cache}
    end
  end

  defp node_state_value(mod, node_id) do
    case Registry.node_state(mod, node_id) do
      m when is_map(m) -> Map.get(m, :state)
      _ -> nil
    end
  end

  # ---- loaded-state persistence (flows/.loaded) ----

  defp loaded_file, do: Path.join(dir(), ".loaded")

  defp all_flow_names do
    dir() |> Path.join("*.ex") |> Path.wildcard() |> Enum.map(&Path.basename(&1, ".ex"))
  end

  defp read_loaded do
    case File.read(loaded_file()) do
      {:ok, content} -> String.split(content, ~r/\s+/, trim: true)
      _ -> []
    end
  end

  defp write_loaded(names) do
    File.mkdir_p!(dir())
    File.write!(loaded_file(), Enum.join(Enum.uniq(names), "\n"))
  end

  defp add_loaded(name), do: write_loaded(read_loaded() ++ [name])
  defp remove_loaded(name), do: write_loaded(read_loaded() -- [name])

  # Discover every flow file and its module atom (cached), sorted by name.
  defp list_flows(cache) do
    {flows, cache} =
      dir()
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.reduce({[], cache}, fn path, {acc, cache} ->
        {mod, cache} = atom_for(path, cache)

        flow = %{
          name: Path.basename(path, ".ex"),
          path: path,
          module: mod,
          loaded: Registry.loaded?(mod)
        }

        {[flow | acc], cache}
      end)

    {flows |> Enum.reverse() |> Enum.sort_by(& &1.name), cache}
  end

  # Route through a node-aware server reference so these calls work from both
  # the app node (local pid) and a dev shell attached to it (remote {name,node}).
  defp call(msg), do: GenServer.call(server(), msg)
  defp call(msg, timeout), do: GenServer.call(server(), msg, timeout)

  defp server do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> pid
      _ -> {__MODULE__, app_node()}
    end
  end

  defp app_node do
    short = Application.get_env(:home_elixir, :node_name, "home_elixir")
    String.to_atom("#{short}@" <> short_host())
  end

  defp short_host do
    case :inet.gethostname() do
      {:ok, cs} -> List.to_string(cs)
      cs -> List.to_string(cs)
    end
    |> String.split(".")
    |> hd()
  end

  defp atom_for(path, cache) do
    key = Path.basename(path, ".ex")

    case Map.fetch(cache, key) do
      {:ok, mod} ->
        {mod, cache}

      :error ->
        mod = compile_atom(path)
        {mod, Map.put(cache, key, mod)}
    end
  end

  defp compile_atom(path) do
    case Code.compile_file(path) do
      [{mod, _binary} | _rest] when is_atom(mod) -> mod
      [{:module, mod, _binary} | _rest] -> mod
      _ -> raise "no flow module found in #{path}"
    end
  end

  defp resolve(name) when is_binary(name) do
    path = Path.join(dir(), "#{name}.ex")
    if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  defp dir, do: Application.get_env(:home_elixir, :flows_dir, "flows")
end
