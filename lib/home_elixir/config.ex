defmodule HomeElixir.Config do
  @moduledoc """
  Layered, editable configuration for flows.

  Resolution order (first hit wins):

    1. flow-specific value — set in the UI, or seeded by the flow's `setup/0`
    2. global value — shared across all flows
    3. `Application.get_env(:home_elixir, key)` — config/*.exs (e.g. secret.exs)
    4. `System.get_env("KEY")` — an environment variable
    5. the supplied default

  Read it from inside a flow — the current flow is the ambient context set by
  the node engine and `setup/0`, so no flow argument is needed:

      HomeElixir.Config.get(:llm_url, "http://localhost:42808/v1")

  Flows declare their editable keys (and defaults) in `setup/0` so they appear
  in the UI and can be overridden without editing code:

      def setup do
        HomeElixir.Config.seed(%{llm_url: "http://localhost:42808/v1"})
        HomeElixir.Config.seed(%{llm_api_key: "sk-..."}, scope: :global)
      end

  `seed/2` is only-if-absent, so a value a user later edits in the UI survives
  flow reloads and restarts. Backed by Mnesia (started by `HomeElixir.Application`
  before any flow loads).
  """

  # One record per scope: {table, scope, %{key => value}}. scope is a flow name
  # ("Examples/mail_check") or the :global atom; flow names are always strings,
  # so :global can never collide. Keys are stored as strings.
  @table :home_elixir_config
  @global :global
  @app_unset :__config_app_unset__
  @seed_unset :__config_seed_unset__

  # Create the table. Mnesia is already up (FlowState.start ran first).
  def start do
    opts =
      if disc?() do
        [{:disc_copies, [node()]}, attributes: [:scope, :data]]
      else
        [attributes: [:scope, :data]]
      end

    case :mnesia.create_table(@table, opts) do
      {:atomic, _} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
      {:aborted, reason} -> raise "Config: mnesia create_table failed: #{inspect(reason)}"
    end

    case :mnesia.wait_for_tables([@table], 10_000) do
      :ok -> :ok
      other -> raise "Config: mnesia table #{@table} not ready: #{inspect(other)}"
    end
  end

  # ---- read ----

  @doc "Resolve a config value per the layered order. Returns the value."
  def get(key, default \\ nil), do: elem(resolve(key, default), 0)

  @doc """
  Resolve a config value, returning `{value, source}` where source is one of
  `:flow`, `:global`, `:app`, `:system`, or `:default`. Used by the UI to badge
  where each value comes from.
  """
  def resolve(key, default \\ nil) do
    ks = to_key(key)

    case current_flow_name() do
      nil ->
        from_global_or_lower(ks, to_atom(key), default)

      name ->
        case Map.fetch(read(name), ks) do
          {:ok, value} -> {value, :flow}
          :error -> from_global_or_lower(ks, to_atom(key), default)
        end
    end
  end

  defp from_global_or_lower(ks, ka, default) do
    unset = @app_unset

    case Map.fetch(read(@global), ks) do
      {:ok, value} ->
        {value, :global}

      :error ->
        case Application.get_env(:home_elixir, ka, unset) do
          ^unset ->
            case System.get_env(String.upcase(ks)) do
              nil -> {default, :default}
              value -> {value, :system}
            end

          value ->
            {value, :app}
        end
    end
  end

  # ---- write ----

  @doc "Set a flow-specific value for the current (ambient) flow."
  def put_flow(key, value) do
    name!()
    |> read()
    |> Map.put(to_key(key), value)
    |> then(fn data -> write(name!(), data) end)
  end

  @doc "Set a global value (shared across all flows)."
  def put_global(key, value), do: put(@global, key, value)

  @doc "Set a value for a scope — a flow name or `:global`."
  def put(scope, key, value) do
    read(scope)
    |> Map.put(to_key(key), value)
    |> then(&write(scope, &1))
  end

  @doc "Remove a value for a scope — subsequent reads fall back to the next layer."
  def delete(scope, key) do
    read(scope)
    |> Map.delete(to_key(key))
    |> then(&write(scope, &1))
  end

  # ---- seeding (setup/0) ----

  @doc """
  Declare editable keys + defaults for the current flow. `scope:` defaults to
  `:flow` (per-flow); pass `scope: :global` for values shared across flows.
  Only-if-absent across the whole resolution chain, so it never shadows a value
  already set at any layer (flow/global/app/system) — a user's edit or app
  config always wins over a re-seed.
  """
  def seed(map, opts \\ []) do
    case Keyword.get(opts, :scope, :flow) do
      :global ->
        Enum.each(map, fn {k, v} -> seed_scope(@global, k, v) end)
        :ok

      :flow ->
        name = name!()
        Enum.each(map, fn {k, v} -> seed_scope(name, k, v) end)
        :ok
    end
  end

  defp seed_scope(scope, key, value) do
    # Only seed when nothing already provides a value (the ambient flow would
    # otherwise resolve to :default). Never shadow an existing flow/global/app/
    # system value — a user's edit or app config always wins over a re-seed.
    if elem(resolve(key, @seed_unset), 1) == :default do
      ks = to_key(key)
      write(scope, Map.put(read(scope), ks, value))
    else
      :ok
    end
  end

  # ---- listing (for the UI) ----

  @doc "All flow-specific config for a flow (name => %{key => value})."
  def flow_config(name), do: read(name)

  @doc "All global config (%{key => value})."
  def global_config, do: read(@global)

  # ---- backup / restore ----

  @doc "Every stored scope as `[{scope, %{key => value}}]` (for backup)."
  def all_scopes do
    tx(fn ->
      :mnesia.match_object({@table, :_, :_})
      |> Enum.map(fn {@table, scope, data} -> {scope, data} end)
    end)
  end

  @doc "Replace a scope's whole config map (for restore)."
  def set_scope(scope, data), do: write(scope, data)

  # ---- helpers ----

  # Does a key look sensitive? The UI masks these and reveals on click.
  def secret?(key) do
    k = to_key(key) |> String.downcase()
    Enum.any?(["token", "password", "secret", "key"], &String.contains?(k, &1))
  end

  defp name! do
    case current_flow_name() do
      nil -> raise "Config called outside a flow context; wrap in HomeElixir.FlowState.as(Flow, fn -> ... end)"
      name -> name
    end
  end

  defp current_flow_name do
    case HomeElixir.FlowState.current_flow() do
      nil -> nil
      mod when is_atom(mod) -> name_for_flow(mod)
    end
  end

  # HomeElixir.Flows.Examples.MailCheck -> "Examples/mail_check". Mirrors
  # Web.name_from_source/1: directory segments keep their case (they're the
  # folder names), only the leaf module is underscored.
  defp name_for_flow(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.HomeElixir.Flows.", "")
    |> String.split(".")
    |> then(fn
      [leaf] -> Macro.underscore(leaf)
      parts ->
        {dirs, [leaf]} = Enum.split(parts, length(parts) - 1)
        Enum.join(dirs ++ [Macro.underscore(leaf)], "/")
    end)
  end

  defp to_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_key(k) when is_binary(k), do: k

  # App-env lookup needs an atom key. Keys reach here either as atoms (code) or
  # as a flow's own seeded keys (UI) — a bounded, developer-controlled set.
  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_atom(k)

  defp tx(fun), do: HomeElixir.Mnesia.tx("Config", fun)

  defp read(scope) do
    tx(fn ->
      case :mnesia.match_object({@table, scope, :_}) do
        [{@table, ^scope, data}] -> data
        _ -> %{}
      end
    end)
  end

  defp write(scope, data), do: tx(fn -> :mnesia.write({@table, scope, data}) end)

  defp disc?, do: HomeElixir.Mnesia.disc?()
end
