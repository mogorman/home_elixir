import Config

# Home Assistant connection. Leave nil to run without HA; set via these or the
# HA_URL / HA_TOKEN environment variables.
config :home_elixir, ha_url: nil, ha_token: nil

# The entity HomeElixir.hello/0 speaks on (the engineering clock). Override
# here or with the HA_HELLO_ENTITY environment variable.
config :home_elixir, hello_entity_id: "media_player.engineering_clock"

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
