import Config

# Home Assistant connection. Leave nil to run without HA; set via these or the
# HA_URL / HA_TOKEN environment variables.
config :home_elixir, ha_url: nil, ha_token: nil

# Distributed-node identity for the dev shell. The server should be started as
# the named node :node_name (see README); the browser IEx tab and a CLI
# `iex --remsh home_elixir` attach to it. node_cookie is shared for auth.
config :home_elixir, node_name: "home_elixir", node_cookie: "home_elixir"

# Tests start their own client, so the app must not auto-start one in :test.
config :home_elixir, auto_start_ha: config_env() != :test

# The web UI is not started during tests.
config :home_elixir, start_web: config_env() != :test

# Restore the loaded/unloaded flow state on restart (persisted in flows/.loaded);
# the first run loads every flow. Off in tests.
config :home_elixir, restore_flows: config_env() != :test

# FlowState persists to disk by default so flows resume their state across
# restarts; set :flow_state_disc to false for in-memory. Disk needs a named
# node — nonode@nohost (mix's default) can't hold disc_copies tables, so disk
# silently falls back to RAM there (tests). The Mnesia schema dir defaults to
# priv/mnesia; set `config :mnesia, dir: <charlist>` to move it (it must be a
# charlist — Mnesia's lists:concat rejects binaries).
config :home_elixir, flow_state_disc: config_env() != :test

# Local HA credentials. config/secret.exs is gitignored; create it to enable HA
# without exporting env vars. HA_URL/HA_TOKEN env vars take precedence (see
# Application.ha_client_child/0). Skipped when the file is absent.
secret = Path.join(__DIR__, "secret.exs")

if File.exists?(secret) do
  import_config secret
end
