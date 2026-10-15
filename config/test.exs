import Config

# Test-env config. Loaded after config/config.exs (and, in :test, without
# config/secret.exs), so these win. Tests run without external services: no HA
# client, no web server, in-memory flow state, and a fixed admin account.
config :home_elixir,
  auto_start_ha: false,
  start_web: false,
  restore_flows: false,
  flow_state_disc: false,
  auth_users: [{"admin", "admin-pass"}]
