import Config

# Home Assistant connection. Leave nil to run without HA; set via these or the
# HA_URL / HA_TOKEN environment variables.
config :home_elixir, ha_url: nil, ha_token: nil

# The entity HomeElixir.hello/0 speaks on (the engineering clock). Override
# here or with the HA_HELLO_ENTITY environment variable.
config :home_elixir, hello_entity_id: "media_player.engineering_clock"

# Tests start their own client, so the app must not auto-start one in :test.
config :home_elixir, auto_start_ha: config_env() != :test

# The web UI is not started during tests.
config :home_elixir, start_web: config_env() != :test
