# Validates HomeElixir.HA.Client against a live Home Assistant.
#
#   HA_TOKEN=... mix run scripts/ha_validate.exs
#   HA_URL=wss://host:8123/api/websocket mix run scripts/ha_validate.exs

url = System.get_env("HA_URL", "wss://ha.rldn.net/api/websocket")
token = System.get_env("HA_TOKEN") || ""

IO.puts("url:   #{url}")
IO.puts("token: " <> if(token == "", do: "<none>", else: "(#{String.length(token)} chars)"))

{:ok, client} =
  HomeElixir.HA.Client.start_link(url: url, token: token, reconnect_delay: 2_000)

IO.puts("waiting up to 15s for a decision...")
t0 = System.monotonic_time(:millisecond)

{final, transitions} =
  Enum.reduce_while(0..75, {nil, []}, fn _, {last, acc} ->
    st = HomeElixir.HA.Client.status(client)
    acc = if(st == last, do: acc, else: [st | acc])

    cond do
      st == :connected ->
        {:halt, {:connected, Enum.reverse(acc)}}

      System.monotonic_time(:millisecond) - t0 > 15_000 ->
        {:halt, {st, Enum.reverse(acc)}}

      true ->
        Process.sleep(200)
        {:cont, {st, acc}}
    end
  end)

IO.puts("transitions: #{inspect(transitions)}")

case final do
  :connected ->
    IO.puts("CONNECTED. Calling get_states (read-only)...")

    case HomeElixir.HA.Client.call(client, "get_states") do
      {:error, e} ->
        IO.puts("get_states error: #{inspect(e)}")

      states when is_list(states) ->
        IO.puts("OK: #{length(states)} entities")

        Enum.take(states, 5)
        |> Enum.each(fn s -> IO.puts("  - #{s["entity_id"]} = #{s["state"]}") end)
    end

  other ->
    IO.puts("NOT connected (final: #{inspect(other)})")
    IO.puts("transport_pid: #{inspect(HomeElixir.HA.Client.transport_pid(client))}")
    IO.puts("Hint: if the log above says 'auth_invalid', the transport reached HA and the token is bad/missing.")
    IO.puts("      if it says a connect error instead, the endpoint/scheme/port is wrong.")
end
