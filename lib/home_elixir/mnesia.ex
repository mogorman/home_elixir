defmodule HomeElixir.Mnesia do
  @moduledoc false
  # Shared Mnesia plumbing for the disc-backed tables (FlowState, Config, Auth):
  # the transaction wrapper, the disc/RAM decision, and the hostname-change hint.

  @doc false
  def tx(label, fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "#{label}: mnesia aborted: #{inspect(reason)}#{stranded_hint(reason)}"
    end
  end

  # Disk only works on a named node; nonode@nohost (mix's default, tests) can't
  # hold disc_copies tables, so fall back to RAM there.
  @doc false
  def disc? do
    Application.get_env(:home_elixir, :flow_state_disc, false) and node() != :nonode@nohost
  end

  # A {:no_exists, table} abort is the signature of a hostname change: the disc
  # schema was written under the old node name and this node has no copy.
  defp stranded_hint(reason) do
    if is_tuple(reason) and elem(reason, 0) == :no_exists do
      " — the Mnesia data is stranded under the previous hostname. Back up and delete " <>
        "priv/mnesia to re-seed (users come from config; flow ownership resets)."
    else
      ""
    end
  end
end
