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

  alias HomeElixir.Registry

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def list, do: GenServer.call(__MODULE__, :list)
  def load(name), do: GenServer.call(__MODULE__, {:load, name})
  def unload(name), do: GenServer.call(__MODULE__, {:unload, name})

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

  def handle_call({:load, name}, _from, cache) do
    case resolve(name) do
      {:ok, path} ->
        {mod, cache} = atom_for(path, cache)

        reply =
          case Registry.load(mod) do
            {:ok, _pid} -> :ok
            {:error, :already_loaded} -> :ok
            {:error, reason} -> {:error, reason}
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
        {:reply, Registry.unload(mod), cache}

      error ->
        {:reply, error, cache}
    end
  end

  # ---- internals ----

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
