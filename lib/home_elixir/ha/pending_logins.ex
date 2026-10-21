defmodule HomeElixir.HA.PendingLogins do
  @moduledoc """
  Shared store for in-flight OAuth logins, keyed by the `state` value.

  A named GenServer so the mapping survives across Cowboy worker processes
  (each HTTP request runs in a short-lived worker; the state minted at
  `/oauth/start` must still be findable at `/oauth/callback`).

  Each entry is `{code_verifier, expiry_ms}` and is consumed exactly once
  (taken on read), so a captured redirect URL cannot be replayed.
  """
  use GenServer

  @name __MODULE__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @impl true
  def init(_), do: {:ok, %{}}

  @doc "Store a pending `state` → `code_verifier`, valid for `ttl_ms`."
  def put(state, code_verifier, ttl_ms) do
    exp = System.system_time(:millisecond) + ttl_ms
    GenServer.call(@name, {:put, state, code_verifier, exp})
  end

  @doc "Atomically fetch-and-delete the verifier for `state` (nil if absent/expired)."
  def take(state) do
    GenServer.call(@name, {:take, state})
  end

  @impl true
  def handle_call({:put, state, verifier, exp}, _from, map) do
    {:reply, :ok, Map.put(map, state, {verifier, exp})}
  end

  @impl true
  def handle_call({:take, state}, _from, map) do
    {result, _} = read(map, state)
    {:reply, result, Map.delete(map, state)}
  end

  # {value_or_nil, _} — value is the verifier if present and unexpired.
  defp read(map, state) do
    now = System.system_time(:millisecond)

    case Map.get(map, state) do
      {verifier, exp} when exp >= now -> {verifier, true}
      _ -> {nil, false}
    end
  end
end
