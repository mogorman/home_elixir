defmodule HomeElixir.Backup do
  @moduledoc """
  Whole-application backup and restore.

  A backup is one JSON document capturing everything the app persists: flow
  source files, config (global + per-flow), user accounts (with password
  hashes), and flow state (metadata + per-flow runtime). Config and per-flow
  runtime hold arbitrary Erlang terms, so they're carried as base64
  `:erlang.term_to_binary` blobs for a lossless round-trip; the rest is JSON.

  Restore is non-destructive: it sets whatever the document contains and leaves
  absent keys alone (so it doubles as a partial import).
  """

  @magic_key "home_elixir_backup"

  # ---- snapshot ----

  @doc "Capture the full app state as a JSON-encodable map."
  def snapshot do
    %{
      @magic_key => 1,
      "version" => app_version(),
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "flows" => flow_sources(),
      "config" => blob(HomeElixir.Config.all_scopes()),
      "users" => users(),
      "flow_state" => %{
        "meta" => blob(HomeElixir.FlowState.dump_meta()),
        "runtime" => blob(HomeElixir.FlowState.dump_runtime())
      }
    }
  end

  # ---- restore ----

  @doc """
  Apply a backup document (the map from `snapshot/0`, or `Jason.decode/1` of one).
  Returns a per-section summary. Raises `ArgumentError` if the magic key is absent.
  """
  def restore(doc) do
    unless is_map(doc) and doc[@magic_key] do
      raise ArgumentError, "not a HomeElixir backup document"
    end

    fs = doc["flow_state"] || %{}

    %{
      ok: true,
      flows: restore_flows(doc["flows"] || %{}),
      config: restore_config(doc["config"]),
      users: restore_users(doc["users"] || []),
      flow_state: restore_meta(fs["meta"]) + restore_runtime(fs["runtime"])
    }
  end

  # ---- internals ----

  defp app_version do
    case :application.get_key(:home_elixir, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "0.0.0"
    end
  end

  # Every .ex under the flows dir, as {name => source} (name has no .ex suffix).
  defp flow_sources do
    dir = Application.get_env(:home_elixir, :flows_dir, "flows")

    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn path -> {Path.rootname(Path.relative_to(path, dir)), File.read!(path)} end)
    |> Map.new()
  end

  defp users do
    HomeElixir.Auth.dump_users()
    |> Enum.map(fn %{name: n, role: r, salt: s, hash: h} ->
      %{"name" => n, "role" => r, "salt" => encode64(s), "hash" => encode64(h)}
    end)
  end

  defp restore_flows(flows) do
    dir = Application.get_env(:home_elixir, :flows_dir, "flows")
    valid = for {name, src} <- flows, valid_name?(name), do: {name, src}

    Enum.each(valid, fn {name, src} ->
      path = Path.join(dir, name <> ".ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end)

    length(valid)
  end

  defp restore_config(nil), do: 0

  defp restore_config(blob) do
    case decode_blob(blob) do
      {:ok, scopes} when is_list(scopes) ->
        Enum.each(scopes, fn {scope, data} -> HomeElixir.Config.set_scope(scope, data) end)
        length(scopes)

      _ ->
        0
    end
  end

  defp restore_users(list) do
    valid =
      (for u <- list, is_map(u), is_binary(u["name"]),
           do: {u, decode64(u["salt"]), decode64(u["hash"])})
      |> Enum.filter(fn {_u, salt, hash} ->
        match?({:ok, _}, salt) and match?({:ok, _}, hash)
      end)

    Enum.each(valid, fn {u, {_, salt}, {_, hash}} ->
      HomeElixir.Auth.restore_user(u["name"], salt, hash, u["role"] || "user")
    end)

    length(valid)
  end

  defp restore_meta(nil), do: 0

  defp restore_meta(blob) do
    case decode_blob(blob) do
      {:ok, map} when is_map(map) ->
        HomeElixir.FlowState.restore_meta(map)
        1

      _ ->
        0
    end
  end

  defp restore_runtime(nil), do: 0

  defp restore_runtime(blob) do
    case decode_blob(blob) do
      {:ok, map} when is_map(map) ->
        HomeElixir.FlowState.restore_runtime(map)
        map_size(map)

      _ ->
        0
    end
  end

  # ---- term blobs: lossless round-trip for arbitrary Erlang terms ----

  defp blob(term), do: term |> :erlang.term_to_binary() |> encode64()

  # A corrupt/foreign blob must degrade to 0, not crash the restore.
  defp decode_blob(s) when is_binary(s) do
    with {:ok, bin} <- decode64(s) do
      try do
        {:ok, :erlang.binary_to_term(bin)}
      catch
        _, _ -> :error
      end
    end
  end

  # ---- base64 ----

  defp encode64(bin) when is_binary(bin), do: Base.encode64(bin)

  defp decode64(nil), do: :error

  defp decode64(s) when is_binary(s) do
    try do
      Base.decode64(s)
    rescue
      ArgumentError -> :error
    end
  end

  defp decode64(_), do: :error

  # Same validity rule as the flow editor: path-style segments, no traversal.
  defp valid_name?(name) do
    is_binary(name) and String.match?(name, ~r/^[A-Za-z0-9_]+(?:\/[A-Za-z0-9_]+)*$/)
  end
end
