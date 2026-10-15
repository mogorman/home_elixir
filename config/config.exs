import Config

# Home Assistant connection. Leave nil to run without HA; set via these or the
# HA_URL / HA_TOKEN environment variables.
config :home_elixir, ha_url: nil, ha_token: nil

# Public origin of the web UI (`scheme://host[:port]`, no trailing slash). Used
# as the Home Assistant OAuth client_id and the base for the /oauth/callback
# redirect_uri, so it must be reachable from the browser.
config :home_elixir, web_base_url: "http://deepthought:4000"

# Distributed-node identity for the dev shell. The server should be started as
# the named node :node_name (see README); the browser IEx tab and a CLI
# `iex --remsh home_elixir` attach to it. node_cookie is shared for auth.
config :home_elixir, node_name: "home_elixir", node_cookie: "home_elixir"

# Auto-start the shared HA client when HA is configured.
config :home_elixir, auto_start_ha: true

# Serves the web UI.
config :home_elixir, start_web: true

# Restore the loaded/unloaded flow state on restart (persisted in the Mnesia
# flow-state DB); the first run loads every flow.
config :home_elixir, restore_flows: true

# FlowState persists to disk by default so flows resume their state across
# restarts; set :flow_state_disc to false for in-memory. Disk needs a named
# node — nonode@nohost (mix's default) can't hold disc_copies tables, so disk
# silently falls back to RAM there (tests). The Mnesia schema dir defaults to
# priv/mnesia; set `config :mnesia, dir: <charlist>` to move it (it must be a
# charlist — Mnesia's lists:concat rejects binaries).
config :home_elixir, flow_state_disc: true

# Auth. `auth_users` seeds local accounts (username => password) on first start;
# an `admin` account always exists — its password from here, or a freshly
# generated one (printed to the log) when none is configured. Sessions are
# in-memory (ETS), so they are lost on restart; `session_ttl_h` is their lifetime.
config :home_elixir,
  auth_users: [],
  session_ttl_h: 168

# Local HA credentials. config/secret.exs is gitignored; create it to enable HA
# without exporting env vars. HA_URL/HA_TOKEN env vars take precedence (see
# Application.ha_client_child/0). Skipped when the file is absent, and never in
# :test — test-only config lives in config/test.exs.
secret = Path.join(__DIR__, "secret.exs")

if config_env() != :test and File.exists?(secret) do
  import_config secret
end

# Test-env overrides (config/test.exs): no external services, in-memory flow
# state, a fixed admin. Imported explicitly so it wins over the defaults above.
if config_env() == :test do
  import_config Path.join(__DIR__, "test.exs")
end
