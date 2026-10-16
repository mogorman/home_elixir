#!/bin/bash
# HomeElixir add-on entrypoint: seed /config, write the app config, render the
# nginx front (one direct port for your reverse proxy), then run the app with
# nginx and keep them alive. If the app exits, the container exits so the HA
# supervisor restarts it.
#
# Access: plain HTTP on DIRECT_PORT (default 8080). Point your reverse proxy
# (or HA) at this port; TLS is terminated there, not here. Login is the app's
# own (admin + admin_password option, or a generated password in the log).
# HA access: in-HA, connects to this HA with the supervisor token automatically.
set -uo pipefail

export HOME=/config
export MIX_ENV=prod
export ERL_AFLAGS="-sname home_elixir -setcookie home_elixir"
export HOME_ELIXIR_CONFIG=/config/config.json

in_ha=false
[ -f /data/options.json ] && in_ha=true
opt() { jq -r ".${1} // empty" /data/options.json 2>/dev/null; }

mkdir -p /config/flows /config/mnesia
# Seed default flows from the release on first start only (editable in the UI).
if [ ! -f /config/.flows-seeded ]; then
  cp -a /opt/home-elixir/flows/. /config/flows/ 2>/dev/null || true
  touch /config/.flows-seeded
fi

# HA: in-HA, connect to this HA with the supervisor token. No user option.
# (An empty HA_TOKEN is truthy in Elixir and would force a doomed connection,
# so we omit ha_url entirely when there's no token -> the app runs HA-less.)
ha_field=""
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  export HA_TOKEN="${SUPERVISOR_TOKEN}"
  ha_field=', "ha_url": "ws://127.0.0.1:8123/api/websocket"'
fi

# Optional admin password (the app's single login). Empty -> the app generates
# one and prints it to the log on first start.
auth_field=""
admin_pw="$(opt admin_password)"
[ -n "$admin_pw" ] && auth_field=", \"auth_users\": [[\"admin\", \"${admin_pw}\", \"admin\"]]"

cat > /config/config.json <<EOF
{
  "home_elixir": {
    "web_host": "127.0.0.1",
    "web_port": 4000,
    "flows_dir": "/config/flows",
    "node_name": "home_elixir",
    "node_cookie": "home_elixir",
    "flow_state_disc": true${ha_field}${auth_field}
  },
  "mnesia": { "dir": "/config/mnesia" }
}
EOF

# ---- render nginx (one direct port, no auth layer; the app handles login) ----
DIRECT_PORT="${HE_DIRECT_PORT:-8080}"
mkdir -p /etc/nginx/servers
rm -f /etc/nginx/servers/*.conf

cat > /etc/nginx/servers/direct.conf <<EOF
server {
    listen ${DIRECT_PORT} default_server;
    listen [::]:${DIRECT_PORT} default_server;
    include /etc/nginx/includes/server_params.conf;
    location / {
        include /etc/nginx/includes/proxy_params.conf;
        proxy_pass http://backend;
    }
}
EOF

echo "home-elixir starting (in_ha=${in_ha} ha=${ha_field:+yes} direct_port=${DIRECT_PORT})"

# ---- run app + nginx, keep alive ----
/opt/home-elixir/bin/home_elixir start &
APP=$!
nginx &
NGINX=$!
while true; do
  if ! kill -0 "$APP" 2>/dev/null; then
    echo "home-elixir exited; exiting so the supervisor restarts the container"
    sleep 2
    exit 0
  fi
  kill -0 "$NGINX" 2>/dev/null || { echo "nginx exited; restarting"; nginx & NGINX=$!; }
  sleep 3
done
