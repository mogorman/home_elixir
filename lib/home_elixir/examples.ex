defmodule HomeElixir.Examples do
  @moduledoc """
  Bundled example flows, kept in a separate read-only `examples/` dir (outside the
  user's `flows/` dir). They can be listed, viewed, and copied into the user's
  flows (verbatim) so they can be edited. They are never loaded or run in place.
  """

  @doc "All example flows as `%{name, path}`, sorted by name."
  def list do
    dir()
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&%{name: rel_name(&1), path: &1})
    |> Enum.sort_by(& &1.name)
  end

  @doc "The source of one example flow, or `{:error, :not_found}`."
  def source(name) do
    case resolve(name) do
      nil -> {:error, :not_found}
      path -> File.read(path)
    end
  end

  @doc """
  Copy an example flow, verbatim, into the user's flows dir under the same base
  name. Returns `{:ok, name}`, or `{:error, :exists}` / `{:error, :not_found}`.
  """
  def copy(name) do
    dest = Path.join(flows_dir(), "#{name}.ex")

    with {:ok, src} <- source(name),
         false <- File.exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, src)
      {:ok, name}
    else
      true -> {:error, :exists}
      {:error, _} = e -> e
    end
  end

  defp dir, do: Application.get_env(:home_elixir, :examples_dir, "examples")
  defp flows_dir, do: Application.get_env(:home_elixir, :flows_dir, "flows")

  defp rel_name(path), do: path |> Path.relative_to(dir()) |> Path.rootname()

  defp resolve(name) do
    path = Path.join(dir(), "#{name}.ex")
    if File.exists?(path), do: path, else: nil
  end
end
