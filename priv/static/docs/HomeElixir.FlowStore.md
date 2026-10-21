# `HomeElixir.FlowStore`
[🔗](https://github.com/mogorman/home_elixir/blob/main/lib/home_elixir/flow_store.ex#L1)

Discovers flow `.ex` files and loads/unloads them at runtime.

Flow files live in a directory (default `flows/`, overridable via the
`:home_elixir, :flows_dir` config). Each file defines one flow module;
`load/1` compiles the file if needed and starts it via `HomeElixir.Registry`,
`unload/1` stops it.

The module atom for each file is taken from the compiler's result and cached,
since `String.to_atom/1` does not reliably yield a matching atom in all VMs.

# `archive`

Archive a flow: force-unload it and hide it from the flow list.

# `check`

Compile a source string and report the result, without loading it into the
flow set. Runs in this GenServer (a stable process), not the request process.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `click`

Inject a message into a node of a loaded flow (used by web controls).

# `clone`

Clone a flow into a sibling file/module with a `Clone` suffix. Returns `{:ok, new_name}`.

# `delete`

Delete a flow: unload it, remove its file, and drop its saved state.

# `flow_ui`

UI elements for one flow (loaded or not), with live `value` when loaded.

# `list`

All flow files in the flows dir, each with its name, path, module, and loaded state.

# `load`

Compile a flow from disk and start it (runs its `setup/0`, if any).

# `loaded?`

Whether a flow is currently loaded (without compiling it).

# `loaded_source`

The source at the flow's last successful load (for editor revert); `:error` if never loaded.

# `reload`

Recompile a flow from disk and restart it (or load it if not running).

# `reload_all`

Reload every currently-loaded flow from disk.

# `rename`

Rename a flow after the editor changed its module name. The new file has
already been written by the caller; this unloads the old flow (if running),
removes the old file, and carries the old flow's ownership to the new name.

# `restore`

Load the flows that were loaded last run (persisted in the Mnesia flow-state
DB). On the very first run (nothing saved yet) this imports the legacy
`flows/.loaded` file if present, else loads every flow file, establishing the
set. Flows that fail to load are logged and skipped.

# `start_link`

# `ui`

UI elements declared by loaded flows (name-keyed, for the web UI).

# `unarchive`

Restore an archived flow back to the flow list (does not load it).

# `unload`

Stop a loaded flow.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
