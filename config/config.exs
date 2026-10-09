import Config

# Home Assistant connection. Leave nil to run without HA; set via these or the
# HA_URL / HA_TOKEN environment variables.
config :home_elixir, ha_url: nil, ha_token: nil

# Tests start their own client, so the app must not auto-start one in :test.
config :home_elixir, auto_start_ha: config_env() != :test
