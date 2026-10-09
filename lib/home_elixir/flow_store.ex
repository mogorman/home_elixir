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

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def list, do: call(:list)
  def load(name), do: call({:load, name})
  def unload(name), do: call({:unload, name})

  @doc "Drop the cached module atom for a flow so the next load recompiles it."
  def forget(name), do: call({:forget, name})

  @doc "Whether a flow is currently loaded (without compiling it)."
  def loaded?(name), do: call({:loaded?, name})

  @doc """
  Compile a source string and report the result, without loading it into the
  flow set. Runs in this GenServer (a stable process), not the request process.
  """
  def check(source), do: call({:check, source})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:list, _from, cache) do
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

    {:reply, flows |> Enum.reverse() |> Enum.sort_by(& &1.name), cache}
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
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        reply =
          case Registry.load(mod) do
            {:ok, _pid} ->
              Logger.info("loaded flow #{name} (#{inspect(mod)})")
              :ok

            {:error, :already_loaded} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        {:reply, reply, cache}

      error ->
        {:reply, error, cache}
    end
  end

  def handle_call({:unload, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)
        result = Registry.unload(mod)
        Logger.info("unloaded flow #{name} (#{inspect(result)})")
        {:reply, result, cache}

      error ->
        {:reply, error, cache}
    end
  end

  # ---- internals ----

  # Route through a node-aware server reference so these calls work from both
  # the app node (local pid) and a dev shell attached to it (remote {name,node}).
  defp call(msg), do: GenServer.call(server(), msg)

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
