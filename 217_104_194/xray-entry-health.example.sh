#!/bin/bash
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN_DIR=${XRAY_ENTRY_HEALTH_RUN_DIR:-/run/xray-entry-health}
CLIENT_CONFIG_LIST=${XRAY_ENTRY_HEALTH_CLIENT_CONFIG_LIST:-/etc/xray-entry-health/client-packet-up.json /etc/xray-entry-health/client-stream-one.json}
MAIN_CONFIG=${XRAY_ENTRY_HEALTH_MAIN_CONFIG:-/usr/local/etc/xray/config.json}
THRESHOLD=${XRAY_ENTRY_HEALTH_THRESHOLD:-3}
COOLDOWN=${XRAY_ENTRY_HEALTH_COOLDOWN:-900}
DRY_RUN=${XRAY_ENTRY_HEALTH_DRY_RUN:-0}
SOCKS_PORT=${XRAY_ENTRY_HEALTH_SOCKS_PORT:-11996}
HTTP_PORT=${XRAY_ENTRY_HEALTH_HTTP_PORT:-18999}

LOCK="$RUN_DIR/lock"
FAIL_FILE="$RUN_DIR/failures"
LAST_RESTART="$RUN_DIR/last-restart"
STATE="$RUN_DIR/state"

mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"
exec 9>"$LOCK"
flock -n 9 || exit 0

read_uint() {
  local value=0

  [ -r "$1" ] && read -r value <"$1"
  case "$value" in
    ''|*[!0-9]*) value=0 ;;
  esac
  printf '%s' "$value"
}

write_state() {
  local value="$1"
  local tmp="$STATE.$$"

  printf '%s checked=%s\n' "$value" "$(date -Is)" | tee "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$STATE"
}

cleanup_probe() {
  local tmp="$1"
  local server_pid="$2"
  local client_pid="$3"

  [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$client_pid" ] || wait "$client_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  python3 - "$tmp" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}

probe_one() {
  local client_config="$1"
  local tmp server_pid='' client_pid='' body rc=1

  tmp=$(mktemp -d "$RUN_DIR/probe.XXXXXX") || return 1

  python3 - "$HTTP_PORT" >"$tmp/http.log" 2>&1 <<'PY' &
import socket
import sys

port = int(sys.argv[1])
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(1)
server.settimeout(12)
connection, _ = server.accept()
connection.settimeout(5)
connection.recv(16384)
body = b"xray-entry-health-ok\n"
headers = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/plain\r\n"
    + b"Content-Length: " + str(len(body)).encode() + b"\r\n"
    + b"Connection: close\r\n\r\n"
)
connection.sendall(headers + body)
connection.close()
server.close()
PY
  server_pid=$!

  xray run -config "$client_config" >"$tmp/xray.log" 2>&1 &
  client_pid=$!

  for _ in $(seq 1 30); do
    ss -lntH "sport = :$SOCKS_PORT" | grep -q ":$SOCKS_PORT" && break
    kill -0 "$client_pid" 2>/dev/null || break
    sleep 0.1
  done

  body=$(curl -fsS --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
    --connect-timeout 3 --max-time 10 "http://127.0.0.1:$HTTP_PORT/" \
    2>/dev/null) || true

  if [ "$body" = "xray-entry-health-ok" ]; then
    rc=0
  else
    echo "entry REALITY/XHTTP handshake probe failed: $client_config" >&2
    tail -n 20 "$tmp/xray.log" >&2 || true
  fi

  cleanup_probe "$tmp" "$server_pid" "$client_pid"
  return "$rc"
}

probe() {
  local client_config

  for client_config in $CLIENT_CONFIG_LIST; do
    if [ ! -r "$client_config" ]; then
      echo "entry health client config is not readable: $client_config" >&2
      return 1
    fi
    probe_one "$client_config" || return 1
  done
}

if probe; then
  printf '0\n' >"$FAIL_FILE"
  write_state 'entry=ok'
  exit 0
fi

failures=$(read_uint "$FAIL_FILE")
failures=$((failures + 1))
printf '%s\n' "$failures" >"$FAIL_FILE"

if [ "$failures" -lt "$THRESHOLD" ]; then
  write_state "entry=degraded($failures/$THRESHOLD)"
  exit 1
fi

now=$(date +%s)
last=$(read_uint "$LAST_RESTART")
if [ $((now - last)) -lt "$COOLDOWN" ]; then
  write_state 'entry=failed(restart-cooldown)'
  exit 1
fi

if ! xray run -test -config "$MAIN_CONFIG" >/dev/null 2>&1; then
  write_state 'entry=failed(config-invalid-restart-suppressed)'
  exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
  write_state 'entry=restart-suppressed(dry-run)'
  exit 1
fi

printf '%s\n' "$now" >"$LAST_RESTART"
echo "entry: restarting xray.service after $failures consecutive probe failures" >&2
systemctl restart xray.service

for _ in $(seq 1 20); do
  systemctl is-active --quiet xray.service \
    && ss -lntH 'sport = :443' | grep -q ':443' \
    && break
  sleep 0.5
done

if probe; then
  printf '0\n' >"$FAIL_FILE"
  write_state 'entry=restarted-ok'
  exit 0
fi

write_state 'entry=restart-failed'
exit 1
