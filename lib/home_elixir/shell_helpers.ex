defmodule HomeElixir.ShellHelpers do
  @moduledoc """
  IEx-style helper functions for the dev shell. Each returns its result as a
  value (instead of printing to io, which this Elixir/OTP build corrupts the
  compiler on when combined with a compile error).
  """

  @doc "Documentation for a module or function, as a string."
  def h(name) do
    case Code.fetch_docs(name) do
      {:ok, :elixir, _, _, _, mod_doc, functions, _} ->
        [to_string(name), "", mod_doc.data || "", "", Enum.map_join(functions, "\n", &fn_doc/1)]

      _ ->
        "no documentation for #{inspect(name)}"
    end
  end

  defp fn_doc({name, arity, doc}) do
    base = "#{name}/#{arity}"
    case doc.data do
      nil -> base
      d -> base <> "  " <> d
    end
  end

  @doc "List files in the current directory."
  def ls, do: File.ls!() |> Enum.sort() |> Enum.join("\n")

  @doc "Current working directory."
  def pwd, do: File.cwd!()

  @doc "Find the pid registered to a name."
  def whereis(name), do: Process.whereis(name)
end
