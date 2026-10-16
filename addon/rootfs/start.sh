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

# HA: prefer the ha_token option (long-lived access token); fall back to
# SUPERVISOR_TOKEN (won't work for the HA WebSocket, but keep for compat).
ha_field=""
ha_opt="$(opt ha_token)"
if [ -n "$ha_opt" ]; then
  export HA_TOKEN="$ha_opt"
  ha_field=', "ha_url": "ws://127.0.0.1:8123/api/websocket"'
  echo "[start] HA configured with ha_token option (${#ha_opt} chars)"
elif [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  export HA_TOKEN="${SUPERVISOR_TOKEN}"
  ha_field=', "ha_url": "ws://127.0.0.1:8123/api/websocket"'
  echo "[start] HA configured with SUPERVISOR_TOKEN (${#SUPERVISOR_TOKEN} chars) - WARNING: may not work for HA WebSocket"
else
  echo "[start] HA not configured (no ha_token or SUPERVISOR_TOKEN)"
fi

# Optional admin password (the app's single login). Empty -> the app generates
# one and prints it to the log on first start.

# Optional web base URL (external URL for OAuth redirects). Empty -> app default.
url_field=""
web_url="$(opt web_base_url)"
[ -n "$web_url" ] && url_field=", \"web_base_url\": \"${web_url}\""

# Optional external HA URL (for OAuth authorize/token reachable by browser).
ha_ext_field=""
ha_ext="$(opt ha_external_url)"
[ -n "$ha_ext" ] && ha_ext_field=", \"ha_external_url\": \"${ha_ext}\""

cat > /config/config.json <<EOF
{
  "home_elixir": {
    "web_host": "127.0.0.1",
    "web_port": 4000,
    "flows_dir": "/config/flows",
    "node_name": "home_elixir",
    "node_cookie": "home_elixir"${ha_field}${url_field}${ha_ext_field}
  },
  "mnesia": { "dir": "/config/mnesia" }
}
EOF

# ---- render nginx ----
DIRECT_PORT="${HE_DIRECT_PORT:-8080}"
mkdir -p /etc/nginx/servers
rm -f /etc/nginx/servers/*.conf

if [ "$(opt direct_port)" = "true" ]; then
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
  echo "[start] direct port enabled on :${DIRECT_PORT}"
else
  echo "[start] direct port disabled (set direct_port=true in options to enable)"
fi

# ---- ingress (embedded HA sidebar panel) ----
# The supervisor proxies /api/ingress/<uuid>/… to this port, preserving the
# path; the app detects that prefix and re-roots its URLs. Always generated —
# the port is not exposed externally; the app's login is the real gate.
INGRESS_PORT=8090
cat > /etc/nginx/servers/ingress.conf <<EOF
server {
    listen 0.0.0.0:${INGRESS_PORT} default_server;
    listen [::]:${INGRESS_PORT} default_server;
    include /etc/nginx/includes/server_params.conf;
    access_log /proc/1/fd/1;
    location / {
        include /etc/nginx/includes/proxy_params.conf;
        proxy_set_header X-Ingress true;
        proxy_pass http://backend;
    }
}
EOF

echo "home-elixir starting (in_ha=${in_ha} ha=${ha_field:+yes} direct_port=${DIRECT_PORT} ingress_port=${INGRESS_PORT})"
echo "home-elixir: /data/options.json exists=$([ -f /data/options.json ] && echo yes || echo no)"

# Clean shutdown. HA/docker send SIGTERM to this shell (PID 1) on stop; without
# a trap the app + nginx are never told to stop and get SIGKILLed, so Mnesia
# never commits its disc tables (often-empty ones included) -> {:no_exists, _}
# on the next boot. Forward SIGTERM to the app so the release halts cleanly
# (MnesiaGuard then :mnesia.stop()s and flushes), and wait for it to finish.
cleanup() {
  echo "home-elixir: stopping cleanly"
  [ -n "${NGINX:-}" ] && kill "$NGINX" 2>/dev/null
  [ -n "${APP:-}" ] && kill -TERM "$APP" 2>/dev/null
  for _ in $(seq 1 25); do
    { [ -z "${APP:-}" ] || ! kill -0 "$APP" 2>/dev/null; } && break
    sleep 1
  done
  [ -n "${APP:-}" ] && kill -KILL "$APP" 2>/dev/null
  exit 0
}
trap cleanup SIGTERM SIGINT

# ---- run app + nginx, keep alive ----
/opt/home-elixir/bin/home_elixir start &
APP=$!
nginx &
NGINX=$!
sleep 2
echo "home-elixir: nginx pid=${NGINX} listening check:"
echo "  port ${DIRECT_PORT}: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${DIRECT_PORT}/ 2>/dev/null || echo 'no response')"
echo "  port ${INGRESS_PORT}: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${INGRESS_PORT}/ 2>/dev/null || echo 'no response')"
while true; do
  if ! kill -0 "$APP" 2>/dev/null; then
    echo "home-elixir exited; exiting so the supervisor restarts the container"
    sleep 2
    exit 0
  fi
  kill -0 "$NGINX" 2>/dev/null || { echo "nginx exited; restarting"; nginx & NGINX=$!; }
  sleep 3
done
