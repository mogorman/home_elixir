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

  @doc "All flow files in the flows dir, each with its name, path, module, and loaded state."
  def list do
    try do
      GenServer.call(server(), :list)
    catch
      :exit, {:timeout, {GenServer, :call, _}} -> :timeout
    end
  end

  @doc "Compile a flow from disk and start it (runs its `setup/0`, if any)."
  def load(name), do: call({:load, name}, @install_timeout)

  @doc "Stop a loaded flow."
  def unload(name), do: call({:unload, name})

  @doc "Archive a flow: force-unload it and hide it from the flow list."
  def archive(name), do: call({:archive, name})

  @doc "Restore an archived flow back to the flow list (does not load it)."
  def unarchive(name), do: call({:unarchive, name})

  @doc "Delete a flow: unload it, remove its file, and drop its saved state."
  def delete(name), do: call({:delete, name})

  @doc "Clone a flow into a sibling file/module with a `Clone` suffix. Returns `{:ok, new_name}`."
  def clone(name), do: call({:clone, name})

  @doc """
  Rename a flow after the editor changed its module name. The new file has
  already been written by the caller; this unloads the old flow (if running),
  removes the old file, and carries the old flow's ownership to the new name.
  """
  def rename(old_name, new_name), do: call({:rename, old_name, new_name})

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

  @doc "Whether a flow is currently loaded (without compiling it)."
  def loaded?(name), do: call({:loaded?, name})

  @doc "The source at the flow's last successful load (for editor revert); `:error` if never loaded."
  def loaded_source(name) do
    case HomeElixir.FlowState.loaded_source(name) do
      src when is_binary(src) -> {:ok, src}
      _ -> :error
    end
  end

  @doc """
  Compile a source string and report the result, without loading it into the
  flow set. Runs in this GenServer (a stable process), not the request process.
  """
  def check(source), do: call({:check, source})

  @doc """
  Load the flows that were loaded last run (persisted in the Mnesia flow-state
  DB). On the very first run (nothing saved yet) this imports the legacy
  `flows/.loaded` file if present, else loads every flow file, establishing the
  set. Flows that fail to load are logged and skipped.
  """
  def restore do
    sweep_orphans()
    names =
      case HomeElixir.FlowState.loaded_names() do
        nil -> first_run_names()
        names -> names
      end

    # Persist the resolved set first: add_loaded during the loop rebuilds from
    # `loaded_names()`, so an unsaved first-run set would be lost to the first
    # successful load (dropping any flow that fails to load).
    HomeElixir.FlowState.save_loaded_names(names)

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
          color: Map.get(ui, :color),
          value: if(ui.type in ["state", "image", "table"], do: node_state_value(mod, node_id), else: nil)
        }
      end

    {:reply, elements, cache}
  end

  def handle_call({:click, name, node, payload}, _from, cache) do
    {reply, cache} =
      case resolve(name) do
        {:ok, path} ->
          {mod, cache} = atom_for(path, cache)

          if is_nil(mod) or not Registry.loaded?(mod) do
            {{:error, :not_loaded}, cache}
          else
            Registry.send_msg(mod, node, HomeElixir.Msg.new(payload || %{}, topic: node))
            {:ok, cache}
          end

        error ->
          {error, cache}
      end

    {:reply, reply, cache}
  end

  def handle_call({:loaded?, name}, _from, cache) do
    # The cache stores `{name => {:ok, module, checksum}}` (see atom_for/2);
    # unwrap the inner tuple before checking the Registry.
    loaded =
      case Map.fetch(cache, name) do
        {:ok, {:ok, mod, _sum}} -> Registry.loaded?(mod)
        _ -> false
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
        e -> {:error, compile_error(e, source)}
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

  # Archive: force-unload (if running), then mark archived.
  def handle_call({:archive, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        cache =
          if mod != nil and Registry.loaded?(mod),
            do: elem(do_unload(name, cache), 1),
            else: cache

        HomeElixir.FlowState.archive(name)
        flow_changed()
        {:reply, :ok, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:unarchive, name}, _from, cache) do
    case resolve(name) do
      {:ok, _path} ->
        HomeElixir.FlowState.unarchive(name)
        flow_changed()
        {:reply, :ok, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:delete, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        cache =
          if mod != nil and Registry.loaded?(mod),
            do: elem(do_unload(name, cache), 1),
            else: cache

        File.rm(path)
        HomeElixir.FlowState.forget_flow(name)
        if mod, do: HomeElixir.FlowState.forget_triggered(mod)
        if mod, do: HomeElixir.FlowState.forget_flow_runtime(mod)
        sweep_orphans()
        flow_changed()
        {:reply, :ok, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:clone, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        if mod do
          {reply, cache} = do_clone(name, path, mod, cache)
          {:reply, reply, cache}
        else
          {:reply, {:error, :compile_error}, cache}
        end

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:rename, old_name, new_name}, _from, cache) do
    case resolve(old_name) do
      {:ok, old_path} ->
        {mod, cache} = atom_for(old_path, cache)

        cache =
          if mod != nil and Registry.loaded?(mod),
            do: elem(do_unload(old_name, cache), 1),
            else: cache

        case HomeElixir.FlowState.flow_owner(old_name) do
          nil -> :ok
          owner -> HomeElixir.FlowState.set_flow_owner(new_name, owner)
        end

        HomeElixir.FlowState.forget_flow(old_name)
        if mod, do: HomeElixir.FlowState.forget_triggered(mod)
        if mod, do: HomeElixir.FlowState.forget_flow_runtime(mod)
        File.rm(old_path)
        cache = Map.delete(cache, old_name)
        sweep_orphans()
        flow_changed()
        {:reply, :ok, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:reload, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        if mod do
          cache = if Registry.loaded?(mod), do: elem(do_unload(name, cache), 1), else: cache
          {reply, cache} = do_load(name, cache)
          {:reply, reply, cache}
        else
          {:reply, {:error, :compile_error}, cache}
        end

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

        if mod do
          loaded = Registry.loaded?(mod)

          case flow_nodes(mod) do
            {:ok, nodes} ->
              elements =
                for {node_id, {_handler, config}} <- nodes,
                    %{type: _t} = ui <- [Map.get(config, :ui)] do
                   %{
                     name: name,
                     node: node_id,
                     type: ui.type,
                     label: Map.get(ui, :label),
                     payload: Map.get(ui, :payload),
                     color: Map.get(ui, :color),
                     value:
                       if(ui.type in ["state", "image", "table"] and loaded,
                         do: node_state_value(mod, node_id),
                         else: nil
                       )
                   }
                end

              {:reply, elements, cache}

            {:error, _} ->
              {:reply, {:error, :compile_error}, cache}
          end
        else
          {:reply, {:error, :compile_error}, cache}
        end

      error ->
        {:reply, error, cache}
    end
  end

  # ---- internals ----

  # Load/unload bodies shared by the `load`/`unload`/`reload`/`reload_all` calls.
  defp do_load(name, cache) do
    sweep_orphans()
    if HomeElixir.FlowState.is_archived?(name) do
      {{:error, :archived}, cache}
    else
      case resolve(name) do
        {:ok, path} ->
          # Recompile from source so an edited flow is picked up on (re)load.
          # Install declared deps first so the compile can reference them.
          src = nil
          reply =
            try do
              src = File.read!(path)
              deps = HomeElixir.Dep.dep_specs(src)
              if deps != [], do: HomeElixir.Dep.install(deps)

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
              e -> {:error, compile_error(e, src)}
            end

          if reply == :ok do
            add_loaded(name)
            record_loaded!(name, path)
            flow_changed()
          end

          {reply, cache}

        error ->
          {error, cache}
      end
    end
  end

  defp do_unload(name, cache) do
    sweep_orphans()
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        if mod do
          result = Registry.unload(mod)
          Logger.info("unloaded flow #{name} (#{inspect(result)})")

          if result == :ok do
            remove_loaded(name)
            flow_changed()
          end

          {result, cache}
        else
          {{:error, :compile_error}, cache}
        end

      error ->
        {error, cache}
    end
  end

  # Copy a flow to a sibling file/module with a "Clone" suffix, inheriting the
  # original's owner. The clone starts unloaded. Returns {:ok, new_name}.
  defp do_clone(name, path, mod, cache) do
    new_name = clone_name(name)
    new_path = Path.join(dir(), "#{new_name}.ex")

    if File.exists?(new_path) do
      {{:error, :exists}, cache}
    else
      case File.read(path) do
        {:ok, source} ->
          new_src =
            String.replace(source, "defmodule #{bare(mod)} do",
              "defmodule #{bare(clone_module(mod))} do")

          File.mkdir_p!(Path.dirname(new_path))
          File.write!(new_path, new_src)

          case HomeElixir.FlowState.flow_owner(name) do
            nil -> :ok
            owner -> HomeElixir.FlowState.set_flow_owner(new_name, owner)
          end

          flow_changed()
          {{:ok, new_name}, cache}

        _ ->
          {{:error, :clone_failed}, cache}
      end
    end
  end

  # "Examples/counter" -> "Examples/counter_clone"; "foo" -> "foo_clone"
  defp clone_name(name) do
    {prefix, [leaf]} = name |> String.split("/") |> Enum.split(-1)
    Enum.join(prefix ++ [leaf <> "_clone"], "/")
  end

  # HomeElixir.Flows.GpuUsageAlert -> HomeElixir.Flows.GpuUsageAlertClone
  defp clone_module(mod) do
    {prefix, [leaf]} =
      to_string(mod)
      |> String.replace_prefix("Elixir.", "")
      |> String.split(".")
      |> Enum.split(-1)

    String.to_atom(Enum.join(prefix ++ [leaf <> "Clone"], "."))
  end

  # The module name as written in a defmodule clause (no "Elixir." prefix).
  defp bare(mod), do: to_string(mod) |> String.replace_prefix("Elixir.", "")

  # Tell web clients the flow set changed so list pages refresh without polling.
  defp flow_changed, do: HomeElixir.UI.Hub.push(:flow_changed, %{})

  defp node_state_value(mod, node_id) do
    case Registry.node_state(mod, node_id) do
      m when is_map(m) -> Map.get(m, :state)
      _ -> nil
    end
  end

  # The flow's node map, or an error if `mod` isn't a flow module. Keeps one bad
  # .ex from raising UndefinedFunctionError and taking down the whole store.
  defp flow_nodes(mod) do
    if function_exported?(mod, :__flow__, 0) do
      {:ok, mod.__flow__().nodes}
    else
      {:error, :not_a_flow}
    end
  end

  # True when the flow declares a Node-RED `device` node — the only node that
  # presents entities via the Node-RED Companion, so it can't work without it.
  defp uses_device_node?(mod) do
    case flow_nodes(mod) do
      {:ok, nodes} ->
        Enum.any?(nodes, fn {_id, {handler, _}} -> handler == HomeElixir.Nodes.Device end)

      {:error, _} ->
        false
    end
  end

  # ---- loaded-state persistence (Mnesia; see HomeElixir.FlowState) ----

  # One-time migration: import the legacy flows/.loaded set, then drop the file.
  defp first_run_names do
    case read_loaded_file() do
      names when names != [] ->
        File.rm(loaded_file())
        names

      _ ->
        all_flow_names()
    end
  end

  defp all_flow_names do
    dir() |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.map(&rel_name/1)
  end

  defp loaded_file, do: Path.join(dir(), ".loaded")

  defp read_loaded_file do
    case File.read(loaded_file()) do
      {:ok, content} -> String.split(content, ~r/\s+/, trim: true)
      _ -> []
    end
  end

  defp add_loaded(name), do: save_loaded((HomeElixir.FlowState.loaded_names() || []) ++ [name])
  defp remove_loaded(name), do: save_loaded((HomeElixir.FlowState.loaded_names() || []) -- [name])
  defp save_loaded(names), do: HomeElixir.FlowState.save_loaded_names(Enum.uniq(names))

  # Discover every flow file (recursively; subfolders become path-style names)
  # and its module atom (cached), sorted by name. Files that fail to compile
  # are skipped (and logged), never fatal.
  defp list_flows(cache) do
    ever = MapSet.new(HomeElixir.FlowState.ever_loaded_names())
    archived = MapSet.new(HomeElixir.FlowState.archived_names())
    sums = HomeElixir.FlowState.loaded_checksums()
    owners = HomeElixir.FlowState.all_flow_owners()
    triggered = HomeElixir.FlowState.all_last_triggered()

    {flows, cache} =
      dir()
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reduce({[], cache}, fn path, {acc, cache} ->
        {mod, cache} = atom_for(path, cache)
        name = rel_name(path)

        if mod do
          loaded = Registry.loaded?(mod)

          flow = %{
            name: name,
            path: path,
            module: mod,
            loaded: loaded,
            owner: Map.get(owners, name),
            archived: MapSet.member?(archived, name),
            last_triggered: Map.get(triggered, mod),
            status: flow_status(loaded, MapSet.member?(ever, name), path, Map.get(sums, name)),
            nodered: uses_device_node?(mod)
          }

          {[flow | acc], cache}
        else
          # Broken (won't compile): still list it so a flow broken between
          # restarts stays visible and can be opened in the editor to fix.
          flow = %{
            name: name,
            path: path,
            module: nil,
            loaded: false,
            owner: Map.get(owners, name),
            archived: MapSet.member?(archived, name),
            last_triggered: nil,
            status: :broken,
            nodered: false
          }

          {[flow | acc], cache}
        end
      end)

    {flows |> Enum.reverse() |> Enum.sort_by(& &1.name), cache}
  end

  # green: loaded and current. yellow: file changed since last load (not applied).
  # red: was loaded, now stopped. grey: never loaded.
  defp flow_status(loaded?, ever?, path, loaded_sum) do
    changed? = is_binary(loaded_sum) and file_checksum(path) != loaded_sum

    cond do
      loaded? and not changed? -> :green
      changed? -> :yellow
      ever? -> :red
      true -> :grey
    end
  end

  defp file_checksum(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  # Store the flow's source + checksum at load time (for status diff + revert).
  defp record_loaded!(name, path) do
    case File.read(path) do
      {:ok, src} ->
        HomeElixir.FlowState.record_load(
          name,
          :crypto.hash(:md5, src) |> Base.encode16(case: :lower),
          src
        )

      _ ->
        :ok
    end
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

  # Module atom for a flow file (cached). Returns nil — and logs — when the
  # file fails to compile, so one broken file can never crash the store.
  # Successful compiles are cached with the file's checksum; a changed file
  # (e.g. a renamed module in the editor) recompiles so the new module is picked
  # up without a restart. Failures are cached with the checksum too, so a broken
  # flow is recompiled (and re-warned) only when the file actually changes —
  # not on every list refresh.
  defp atom_for(path, cache) do
    key = rel_name(path)
    sum = file_checksum(path)

    case Map.fetch(cache, key) do
      {:ok, {:ok, mod, ^sum}} ->
        {mod, cache}

      {:ok, {:err, ^sum}} ->
        {nil, cache}

      _ ->
        case compile_atom_safe(path) do
          {:ok, mod} ->
            {mod, Map.put(cache, key, {:ok, mod, sum})}

          {:error, msg} ->
            Logger.warning("skipping flow #{key}: #{msg}")
            {nil, Map.put(cache, key, {:err, sum})}
        end
    end
  end

  defp compile_atom_safe(path) do
    src = File.read(path)

    try do
      {:ok, compile_atom(path)}
    rescue
      e -> {:error, compile_error(e, src)}
    end
  end

  # A `defmodule` with a lowercase segment raises ArgumentError whose default
  # message embeds the raw AST. Prettify that one case, using the name found in
  # the source; pass every other error through untouched.
  defp compile_error(e, source) do
    msg = Exception.message(e)

    if String.starts_with?(msg, "invalid module name") do
      base = "Elixir module names must start with an uppercase letter"
      name = if is_binary(source), do: Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source), else: nil

      case name do
        [_, n] -> "invalid module name `#{n}` — #{base} (try `#{suggested_name(n)}`)."
        _ -> "invalid module name — #{base}."
      end
    else
      msg
    end
  end

  # "HomeElixir.Flows.check_screenshot" -> "HomeElixir.Flows.CheckScreenshot"
  defp suggested_name(name) do
    {prefix, [leaf]} = name |> String.split(".") |> Enum.split(-1)
    Enum.join(prefix ++ [Macro.camelize(leaf)], ".")
  end

  # A flow file's name relative to the flows dir, without the extension —
  # subfolders become path-style names ("LivingRoom/counter"), unique across
  # folders, and existing flat names are unchanged.
  defp rel_name(path), do: path |> Path.relative_to(dir()) |> Path.rootname()

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

  # Every module atom a current flow file declares (regex on the `defmodule`
  # line — no compile, so it still works on a broken file). Prefix-agnostic.
  @doc "The set of module atoms declared by the current flow files."
  def declared_modules do
    dir()
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, src} ->
          case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, src) do
            [_, mod] -> [qualify_module(mod)]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> MapSet.new()
  end

  # Runtime records are keyed by the *compiled* module atom, and the compiler
  # auto-prepends `Elixir.` to a `defmodule` name that isn't already qualified.
  # Match that so a flow's own module is recognized as declared (else the sweep
  # would drop its record).
  defp qualify_module(mod) do
    mod = if String.starts_with?(mod, "Elixir."), do: mod, else: "Elixir." <> mod
    String.to_atom(mod)
  end

  # Drop orphaned flow-state records (modules no current flow file declares).
  defp sweep_orphans do
    HomeElixir.FlowState.sweep_orphans(declared_modules())
  end

  defp dir, do: Application.get_env(:home_elixir, :flows_dir, "flows")
end
