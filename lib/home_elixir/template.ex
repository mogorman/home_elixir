defmodule HomeElixir.Template do
  @moduledoc false

  @templates_path Path.join(["priv", "templates"])

  def render(name, assigns \\ %{}) do
    path = Path.join(template_dir(), name)
    bindings = if is_map(assigns), do: Map.to_list(assigns), else: assigns
    EEx.eval_file(path, bindings)
  end

  defp template_dir do
    case :code.priv_dir(:home_elixir) do
      {:error, :undef} -> Path.expand(@templates_path, Path.dirname(__DIR__))
      dir -> Path.join(List.to_string(dir), "templates")
    end
  end
end
