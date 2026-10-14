import Config

# Runtime config for the release. In dev (mix run) this runs after
# config.exs; in the release it runs before the app starts, so overrides
# below win in both.
#
# A supervisor (e.g. the NixOS module) can point HOME_ELIXIR_CONFIG at a JSON
# file of config overrides, applied per app:
#
#   {"home_elixir": {"ha_url": "...", "flows_dir": "..."},
#    "mnesia": {"dir": "/var/lib/home-elixir/mnesia"}}
#
# Keys are applied as `config :app, key: value`. Secrets (HA token) belong in
# the HA_TOKEN env var, not this file.
if path = System.get_env("HOME_ELIXIR_CONFIG") do
  for {app, pairs} <- File.read!(path) |> Jason.decode!() do
    kv = for {k, v} <- pairs, do: {String.to_atom(k), v}
    config(String.to_atom(app), kv)
  end
end
