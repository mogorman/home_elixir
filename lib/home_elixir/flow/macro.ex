defmodule HomeElixir.Flow.Macro do
  @moduledoc false

  defmacro node(id, handler) do
    quote do: node(unquote(id), unquote(handler), %{})
  end

  defmacro node(id, handler, config) do
    quote do
      @fe_nodes {unquote(id), {unquote(handler), Map.new(unquote(config))}}
    end
  end

  # Grouped form: one target, many sources — wire(["a", "b"], "c").
  defmacro wire(from, to) when is_list(from) do
    quote do
      for f <- unquote(from) do
        @fe_wires {f, unquote(to)}
      end
    end
  end

  defmacro wire(from, to) do
    quote do: @fe_wires {unquote(from), unquote(to)}
  end

  # Registers the flow's own web page: `web_page("/path")` routes GET /path to
  # the flow's `page_html/0` EEx template. `public: true` opts out of auth.
  defmacro web_page(path) do
    quote do: web_page(unquote(path), [])
  end

  defmacro web_page(path, opts) do
    quote do: @fe_web_page {unquote(path), unquote(opts)}
  end
end
