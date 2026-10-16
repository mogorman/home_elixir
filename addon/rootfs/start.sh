#!/bin/bash
# HomeElixir add-on entrypoint: seed /config, write the app config, render the
# nginx front (ingress panel + direct port), then run the app with nginx and
# keep them alive. If the app exits, the container exits so the HA supervisor
# restarts it.
set -uo pipefail

export HOME=/config
export MIX_ENV=prod
export ERL_AFLAGS="-sname home_elixir -setcookie home_elixir"
export HOME_ELIXIR_CONFIG=/config/config.json

# Loaded best-effort; used for Supervisor port/interface discovery in-HA only.
[ -f /usr/local/lib/bashio/bashio.sh ] && . /usr/local/lib/bashio/bashio.sh

in_ha=false
[ -f /data/options.json ] && in_ha=true
opt() { jq -r ".${1} // empty" /data/options.json 2>/dev/null; }

mkdir -p /config/flows /config/mnesia
# Seed default flows from the release on first start only (editable in the UI).
if [ ! -f /config/.flows-seeded ]; then
  cp -a /opt/home-elixir/flows/. /config/flows/ 2>/dev/null || true
  touch /config/.flows-seeded
fi

# HA is configured only when a supervisor token is present (in-HA). An empty
# HA_TOKEN is truthy in Elixir and would force a doomed HA connection, so we
# omit it (and ha_url) entirely when there's no token -> the app runs HA-less.
ha_field=""
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  export HA_TOKEN="${SUPERVISOR_TOKEN}"
  ha_url="ws://127.0.0.1:8123/api/websocket"
  [ -f /data/options.json ] && ha_url="$(opt ha_url)" && [ -n "$ha_url" ] || ha_url="ws://127.0.0.1:8123/api/websocket"
  ha_field=", \"ha_url\": \"${ha_url}\""
fi

cat > /config/config.json <<EOF
{
  "home_elixir": {
    "web_host": "127.0.0.1",
    "web_port": 4000,
    "flows_dir": "/config/flows",
    "node_name": "home_elixir",
    "node_cookie": "home_elixir"${ha_field}
  },
  "mnesia": { "dir": "/config/mnesia" }
}
EOF

# ---- render nginx server configs ----
mkdir -p /etc/nginx/servers
rm -f /etc/nginx/servers/*.conf

# Ingress (embedded HA panel) - only in-HA, where the Supervisor assigns it.
if [ "$in_ha" = true ]; then
  ip="$(bashio::app.ip_address 2>/dev/null || true)"
  port="$(bashio::app.ingress_port 2>/dev/null || true)"
  if [ -n "${ip:-}" ] && [ -n "${port:-}" ]; then
    cat > /etc/nginx/servers/ingress.conf <<EOF
server {
    listen ${ip}:${port} default_server;
    include /etc/nginx/includes/server_params.conf;
    include /etc/nginx/includes/proxy_params.conf;
    location / {
        allow   172.30.32.2;
        deny    all;
        proxy_pass http://backend;
    }
}
EOF
  fi
fi

# Direct access (reachable from outside, e.g. an external nginx).
ssl=false; leave_open=false; certfile=fullchain.pem; keyfile=privkey.pem; direct_port=""
if [ "$in_ha" = true ]; then
  ssl="$(opt ssl)";        [ "$ssl" = "true" ] || ssl=false
  leave_open="$(opt leave_front_door_open)"; [ "$leave_open" = "true" ] || leave_open=false
  certfile="$(opt certfile)"; [ -n "$certfile" ] || certfile=fullchain.pem
  keyfile="$(opt keyfile)";   [ -n "$keyfile" ]   || keyfile=privkey.pem
  direct_port="$(bashio::app.port 80 2>/dev/null || true)"
fi
[ -n "$direct_port" ] || direct_port="${HE_DIRECT_PORT:-8080}"

auth_block=""
auth_req=""
if [ "$in_ha" = true ] && [ "$leave_open" != true ]; then
  auth_block='    location = /authentication {
        internal;
        proxy_pass              http://supervisor/auth;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length "";
        proxy_set_header        X-Supervisor-Token "'"${SUPERVISOR_TOKEN:-}"'";
    }
'
  auth_req='        auth_request /authentication;'
fi

listen_lines="    listen ${direct_port} default_server;
    listen [::]:${direct_port} default_server;"
ssl_lines=""
if [ "$ssl" = true ]; then
  listen_lines="    listen ${direct_port} default_server ssl;
    listen [::]:${direct_port} default_server ssl;
    http2 on;"
  ssl_lines='
    include /etc/nginx/includes/ssl_params.conf;
    ssl_certificate /ssl/'"${certfile}"';
    ssl_certificate_key /ssl/'"${keyfile}"';'
fi

cat > /etc/nginx/servers/direct.conf <<EOF
server {
${listen_lines}
    include /etc/nginx/includes/server_params.conf;
    include /etc/nginx/includes/proxy_params.conf;
${ssl_lines}
${auth_block}
    location / {
${auth_req}
        proxy_pass http://backend;
    }
}
EOF

echo "home-elixir starting (in_ha=${in_ha} ha=${ha_url:-none} direct_port=${direct_port})"

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
