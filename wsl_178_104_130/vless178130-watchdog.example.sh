#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF='/usr/local/bin/vless178130-watchdog'
PID='/run/vless178130-watchdog.pid'
LOG='/tmp/vless178130-watchdog.log'
STATE='/run/vless178130-switch.state'
SING_CONFIG='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'
EXPECTED='198.51.100.130'

write_state() {
  umask 077
  tmp="$STATE.$$"
  printf '%s checked=%s\n' "$1" "$(date -Is)" >"$tmp"
  mv -f "$tmp" "$STATE"
}

case "$1" in
  start)
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" start; fi
    if [ -s "$PID" ] && start-stop-daemon --status --pidfile "$PID" >/dev/null 2>&1; then
      echo "watchdog already running pid=$(cat "$PID")"
      exit 0
    fi
    rm -f "$PID"
    touch "$LOG"
    chmod 600 "$LOG"
    start-stop-daemon --start --background --make-pidfile --pidfile "$PID" --startas "$SELF" --output "$LOG" -- run
    sleep 1
    start-stop-daemon --status --pidfile "$PID"
    echo "watchdog started pid=$(cat "$PID")"
    ;;
  stop)
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" stop; fi
    start-stop-daemon --stop --oknodo --retry=TERM/3/KILL/2 --pidfile "$PID" --remove-pidfile
    ;;
  status)
    if [ -s "$PID" ] && start-stop-daemon --status --pidfile "$PID" >/dev/null 2>&1; then
      echo "running pid=$(cat "$PID")"
      exit 0
    fi
    echo 'stopped'
    exit 1
    ;;
  run)
    if [ "$EUID" -ne 0 ]; then exit 77; fi
    trap 'rm -f "$PID"' EXIT
    failures=0
    echo "watchdog loop start $(date -Is)"
    while sleep 30; do
      if ! pgrep -f "^/usr/local/bin/sing-box run -c $SING_CONFIG$" >/dev/null 2>&1 || ! ip link show tun-vless178130 >/dev/null 2>&1; then
        echo "new profile is no longer active; watchdog exits $(date -Is)"
        exit 0
      fi
      if /usr/local/bin/check-vless178130 --quick --quiet; then
        failures=0
        write_state "HEALTHY source=watchdog exit=$EXPECTED"
        continue
      fi
      failures=$((failures + 1))
      write_state "DEGRADED source=watchdog failures=$failures"
      echo "health failure $failures at $(date -Is)"
      if [ "$failures" -ge 2 ]; then
        /usr/local/bin/recover-vless178130 || true
        failures=0
        if ! pgrep -f "^/usr/local/bin/sing-box run -c $SING_CONFIG$" >/dev/null 2>&1; then
          echo "recovery selected rollback; watchdog exits $(date -Is)"
          exit 0
        fi
      fi
    done
    ;;
  *)
    echo "usage: $0 {start|stop|status|run}" >&2
    exit 64
    ;;
esac
