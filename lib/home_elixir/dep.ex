defmodule HomeElixir.Dep do
  @moduledoc """
  Install external Hex dependencies at runtime, Livebook-style, without editing
  `mix.exs`.

  `install/1` builds the given deps in an isolated throwaway Mix project under
  the user cache — as a `mix` subprocess, since `Mix.install/1` refuses to run
  inside an active Mix project — and adds the resulting code paths to the
  running VM. Flows call this from their `setup/0`.

  The build is cached in `~/.cache/home_elixir/deps`, so only the first install
  of a dep hits the network; later loads and restarts reuse it. Because the
  project is shared, `install/1` accumulates the union of all deps ever
  requested, so   one flow's install never evicts another flow's compiled beams.

  At boot, `reset_if_stale/0` wipes the compiled cache only when the set of
  deps declared across the flow files changed since last boot — so a changed
  set rebuilds clean, while an unchanged set reuses the warm cache.
  """

  require Logger

  @build_root Path.join([".cache", "home_elixir", "deps"])

  @doc "Fetch, compile, and load `deps` (a keyword list, e.g. `[{:timex, \"~> 3.7\"}]`)."
  def install(deps) when is_list(deps) do
    dir = build_dir()
    ensure_project!(dir, union!(dir, deps))
    mix!(dir, ["deps.get"])
    mix!(dir, ["deps.compile"])
    add_paths!(dir)
    :ok
  end

  # The deps every flow file currently declares, as a canonical (deduped,
  # sorted) list of `{name_atom, "version"}` — only the `Dep.install` specs,
  # never the flow code, so a logic-only edit leaves this unchanged.
  @doc false
  def deps_from_flows do
    dir = Application.get_env(:home_elixir, :flows_dir, "flows")

    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&File.read!/1)
    |> Enum.flat_map(&dep_specs/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{to_string(elem(&1, 0)), elem(&1, 1)})
  end

  # At boot, wipe the throwaway project's `_build` + dep union when the set of
  # declared deps changed since last boot (a flow added/deleted, or a dep
  # version edited). Unchanged boots skip this and reuse the warm `_build`.
  # The hex source cache (`deps/`) and mix sources are kept, so a rebuild is
  # fast and offline.
  @doc false
  def reset_if_stale do
    dir = build_dir()
    file = Path.join(dir, "flow_deps")
    current = inspect(deps_from_flows())

    last =
      case File.read(file) do
        {:ok, s} -> String.trim(s)
        _ -> nil
      end

    if last == current do
      :ok
    else
      File.rm_rf!(Path.join(dir, "_build"))
      File.rm(Path.join(dir, "installed_deps"))
      File.write!(file, current)
      Logger.info("dep reset: flow deps changed (#{current}) -> wiped _build + union")
      :ok
    end
  end

  # ---- internals ----

  # `{:name, "version"}` pairs declared in a flow file's `Dep.install([...])`.
  defp dep_specs(src) do
    for [_, inner] <- Regex.scan(~r/Dep\.install\(\s*\[([^\]]*)\]/s, src),
        [_, name, ver] <- Regex.scan(~r/\{:(\w+)\s*,\s*"([^"]+)"\}/, inner) do
      {String.to_atom(name), ver}
    end
  end

  defp build_dir do
    dir = Path.join([System.user_home!(), @build_root])
    File.mkdir_p!(dir)
    dir
  end

  # The throwaway project is shared by every flow, so its dep set is the union
  # of everything ever installed: if installing one flow's deps replaced the
  # set, it would wipe another flow's compiled beams out of _build (their
  # modules would then fail to load lazily at runtime).
  defp union!(dir, deps) do
    file = Path.join(dir, "installed_deps")

    existing =
      case File.read(file) do
        {:ok, src} -> elem(Code.eval_string(src), 0)
        _ -> []
      end

    existing_names = for dep <- existing, do: to_string(elem(dep, 0))
    fresh = for dep <- deps, to_string(elem(dep, 0)) not in existing_names, do: dep
    all = existing ++ fresh

    Logger.info(
      "dep union: requested=#{inspect(deps)} existing=#{inspect(existing)} -> #{inspect(all)}"
    )

    File.write!(file, inspect(all))
    all
  end

  # Build in the env the app runs in. The subprocess inherits this same OS
  # `MIX_ENV`, so its `_build/<env>` matches what we load.
  defp env, do: System.get_env("MIX_ENV") || "dev"

  # Rewrite the throwaway mix.exs (and drop its lock) only when the deps change,
  # so re-installing the same set is a cheap no-op.
  defp ensure_project!(dir, deps) do
    mix_exs = Path.join(dir, "mix.exs")

    if File.exists?(mix_exs) and File.read!(mix_exs) == project_source(deps) do
      :ok
    else
      File.write!(mix_exs, project_source(deps))
      File.rm(Path.join(dir, "mix.lock"))
      # A changed deps set means a fresh, correctly-ordered build (a stale
      # _build breaks timex-style deps that compile against sibling deps).
      File.rm_rf!(Path.join(dir, "_build"))
      :ok
    end
  end

  defp project_source(deps) do
    [
      "defmodule HomeElixirDeps.MixProject do\n",
      "  use Mix.Project\n",
      "  def project, do: [app: :home_elixir_deps, version: \"0.0.0\", deps: #{inspect(deps)}]\n",
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp mix!(dir, args) do
    # Strip node flags: the subprocess BEAM must not inherit the app's node
    # name (ERL_AFLAGS), or it exits on a node-name collision before doing
    # anything.
    # Blank out (can't unset — System.cmd's env only overrides, never removes)
    # the node flags so the subprocess BEAM doesn't collide with the app's
    # node name.
    env =
      System.get_env()
      |> Map.put("ERL_AFLAGS", "")
      |> Map.put("ERL_ARGS", "")

    # stderr_to_stdout: mix/BEAM write failures to stderr; without this the
    # error message below is empty.
    {out, status} = System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)

    if status == 0 do
      :ok
    else
      raise "mix #{Enum.join(args, " ")} failed (exit #{status}):\n#{out}"
    end
  end

  # Load every compiled dep into the VM and start its OTP app (if it has one).
  # Two passes: all ebin paths first, then all apps — an app's declared
  # dependencies may sort after it, so its .app file must be on the code path
  # before we start it. App names come from the .app file, not the (versioned)
  # lib dir name.
  defp add_paths!(dir) do
    ebins =
      for dep_dir <- Path.wildcard(Path.join(dir, "_build/#{env()}/lib") <> "/*"),
          ebin = Path.join(dep_dir, "ebin"),
          File.dir?(ebin),
          do: ebin

    Enum.each(ebins, &Code.append_path/1)

    for ebin <- ebins do
      case Path.wildcard(Path.join(ebin, "*.app")) do
        [app_file] ->
          Application.ensure_all_started(Path.basename(app_file, ".app") |> String.to_atom())

        _ ->
          :ok
      end
    end

    :ok
  end
end
