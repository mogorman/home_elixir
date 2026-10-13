defmodule HomeElixir.Dep do
  @moduledoc """
  Install external Hex dependencies at runtime, Livebook-style, without editing
  `mix.exs`.

  `install/1` builds the given deps in an isolated throwaway Mix project under
  the user cache — as a `mix` subprocess, since `Mix.install/1` refuses to run
  inside an active Mix project — and adds the resulting code paths to the
  running VM. Flows call this from their `setup/0`.

  The build is cached in `~/.cache/home_elixir/deps`, so only the first install
  of a dep set hits the network; later loads and restarts reuse it.
  """

  @build_root Path.join([".cache", "home_elixir", "deps"])

  @doc "Fetch, compile, and load `deps` (a keyword list, e.g. `[{:timex, \"~> 3.7\"}]`)."
  def install(deps) when is_list(deps) do
    dir = build_dir()
    ensure_project!(dir, deps)
    mix!(dir, ["deps.get"])
    mix!(dir, ["deps.compile"])
    add_paths!(dir)
    :ok
  end

  # ---- internals ----

  defp build_dir do
    dir = Path.join([System.user_home!(), @build_root])
    File.mkdir_p!(dir)
    dir
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
