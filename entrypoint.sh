#!/bin/sh
# Halvo node entrypoint (PID 1 supervisor).
# Starts, each in its own auto-restart loop so no single crash can take the rest down:
#   - busybox httpd   : 0.0.0.0:$PORT  -> /health, /<SUB_PATH> subscription
#   - sing-box        : 127.0.0.1:18001 VLESS+WS (reached via the fixed CF tunnel)
#   - cloudflared     : fixed tunnel, --protocol http2, token from env only
#   - nezha-agent     : old panel, config generated from env only
# NOTHING secret is baked into the image: every UUID / token / secret below is read
# from environment variables at container start. Missing optional env => that part
# is skipped with a log line, the HTTP service keeps running.

set -u

PORT="${PORT:-3000}"
SUB_PATH="${SUB_PATH:-sub}"
# normalise sub path: strip leading/trailing slashes (it is a single filename)
SUB_PATH=$(printf %s "$SUB_PATH" | sed 's|^/*||; s|/*$||')
[ -z "$SUB_PATH" ] && SUB_PATH="sub"

RUN_DIR="/app/run"
WWW_DIR="/app/www"
mkdir -p "$RUN_DIR" "$WWW_DIR"

# ---- node identity (env first, generated+persisted in container fs as fallback) ----
if [ -n "${VLESS_UUID:-}" ]; then
  NODE_UUID="$VLESS_UUID"
elif [ -f "$RUN_DIR/uuid" ]; then
  NODE_UUID=$(cat "$RUN_DIR/uuid")
else
  NODE_UUID=$(cat /proc/sys/kernel/random/uuid)
  printf %s "$NODE_UUID" > "$RUN_DIR/uuid"
fi
WS_PATH="${WS_PATH:-/halvo-ws}"
case "$WS_PATH" in /*) ;; *) WS_PATH="/$WS_PATH" ;; esac

NODE_ADDR="${NODE_ADDR:-cf.877774.xyz}"        # preferred CF edge address (user rule)
NODE_PORT="${NODE_PORT:-443}"
NODE_HOST="${NODE_HOST:-}"                     # tunnel hostname -> SNI / WS Host
NODE_NAME="${NODE_NAME:-halvo-node}"
LINK_HOST="${NODE_HOST:-$NODE_ADDR}"

# ---- sing-box config: VLESS+WS on loopback only, tunnel is the only way in ----
cat > "$RUN_DIR/sing-box.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": 18001,
      "users": [ { "uuid": "$NODE_UUID" } ],
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

# ---- subscription file: one VLESS+WS link, base64, served at /$SUB_PATH ----
ENC_PATH=$(printf %s "$WS_PATH" | sed 's|/|%2F|g')
LINK="vless://${NODE_UUID}@${NODE_ADDR}:${NODE_PORT}?encryption=none&security=tls&sni=${LINK_HOST}&type=ws&host=${LINK_HOST}&path=${ENC_PATH}#${NODE_NAME}"
printf %s "$LINK" | base64 | tr -d '\n' > "$WWW_DIR/$SUB_PATH"
printf '\n' >> "$WWW_DIR/$SUB_PATH"
echo "ok" > "$WWW_DIR/health"
printf 'halvo-node running. subscription: /%s\n' "$SUB_PATH" > "$WWW_DIR/index.html"
echo "[halvo] config ready: port=$PORT sub=/$SUB_PATH ws-listen=127.0.0.1:18001"

# ---- nezha agent config (only when the client secret is provided) ----
NZ_READY=0
if [ -n "${NZ_CLIENT_SECRET:-}" ]; then
  if [ -n "${NZ_UUID:-}" ]; then
    AGENT_UUID="$NZ_UUID"
  elif [ -f "$RUN_DIR/nz-uuid" ]; then
    AGENT_UUID=$(cat "$RUN_DIR/nz-uuid")
  else
    AGENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    printf %s "$AGENT_UUID" > "$RUN_DIR/nz-uuid"
  fi
  NZ_SERVER="${NZ_SERVER:-nezha2026.5785787.xyz:443}"
  NZ_TLS="${NZ_TLS:-true}"
  cat > "$RUN_DIR/nezha-config.yml" <<EOF
client_secret: <redacted>
debug: false
disable_auto_update: true
disable_command_execute: true
server: $NZ_SERVER
tls: $NZ_TLS
uuid: $AGENT_UUID
EOF
  NZ_READY=1
else
  echo "[halvo] NZ_CLIENT_SECRET not set, nezha agent skipped"
fi

# test hook for local validation (used by the build self-check, not in production):
# generate every config/file, then exit before starting any service.
if [ "${HALVO_CONFIG_ONLY:-0}" = "1" ]; then
  echo "[halvo] config-only mode, generated files:"
  ls -la "$RUN_DIR" "$WWW_DIR"
  exit 0
fi

# ---- supervision: one restart loop per child, all in background ----
guard() {
  name="$1"; shift
  while true; do
    echo "[halvo] starting $name"
    "$@" || echo "[halvo] $name exited rc=$?, restarting in 5s"
    sleep 5
  done
}

guard httpd       busybox httpd -f -p "$PORT" -h "$WWW_DIR" &
guard sing-box    /usr/local/bin/sing-box run -c "$RUN_DIR/sing-box.json" &

if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  # TUNNEL_TOKEN env keeps the token out of the process argument list.
  guard cloudflared env TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
    /usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run &
else
  echo "[halvo] CF_TUNNEL_TOKEN not set, cloudflared skipped"
fi

if [ "$NZ_READY" = "1" ]; then
  guard nezha-agent /usr/local/bin/nezha-agent -c "$RUN_DIR/nezha-config.yml" &
else
  :
fi

echo "[halvo] all services launched, supervising"
wait
