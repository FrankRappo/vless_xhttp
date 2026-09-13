#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF='/usr/local/bin/vless104130-ssh-watchdog'
MANAGER='/usr/local/bin/vless104130-ssh'
PID='/run/vless104130-ssh-watchdog.pid'
LOG='/run/vless104130-ssh/watchdog.log'
ENABLED='/run/vless104130-ssh.enabled'
PROFILE_FILE='/etc/vless-wsl/profile'
SSH_PID='/run/vless104130-ssh/ssh.pid'
XRAY_PID='/run/vless104130-ssh/xray.pid'
SING_PID='/run/vless104130-ssh/sing-box.pid'
FORWARD_PORT=18443
SOCKS_PORT=18130
TUN_NAME='tun-vlessssh130'

pidfile_process_running() {
  local pidfile="$1" pid
  [ -s "$pidfile" ] || return 1
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null
}

structure_is_alive() {
  pidfile_process_running "$SSH_PID" &&
    pidfile_process_running "$XRAY_PID" &&
    pidfile_process_running "$SING_PID" &&
    ip link show "$TUN_NAME" >/dev/null 2>&1 &&
    ss -lntH | grep -qE "127\\.0\\.0\\.1:${FORWARD_PORT}([[:space:]]|$)" &&
    ss -lntH | grep -qE "127\\.0\\.0\\.1:${SOCKS_PORT}([[:space:]]|$)"
}

case "${1:-status}" in
  start)
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" start; fi
    if [ -s "$PID" ] && start-stop-daemon --status --pidfile "$PID" >/dev/null 2>&1; then
      echo "watchdog already running pid=$(cat "$PID")"
      exit 0
    fi
    rm -f "$PID"
    touch "$LOG"
    chmod 0600 "$LOG"
    start-stop-daemon --start --background --make-pidfile --pidfile "$PID" \
      --startas "$SELF" --output "$LOG" -- run
    sleep 1
    start-stop-daemon --status --pidfile "$PID"
    echo "watchdog started pid=$(cat "$PID")"
    ;;
  stop)
    if [ "$EUID" -ne 0 ]; then exec sudo "$0" stop; fi
    start-stop-daemon --stop --oknodo --retry=TERM/3/KILL/2 \
      --pidfile "$PID" --remove-pidfile
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
    while sleep 15; do
      if [ ! -e "$ENABLED" ] || [ ! -r "$PROFILE_FILE" ] ||
          [ "$(tr -d '[:space:]' <"$PROFILE_FILE")" != '104-130-over-ssh' ]; then
        echo "profile disabled or deselected; watchdog exits $(date -Is)"
        exit 0
      fi

      if ! structure_is_alive; then
        echo "transport failure; immediate fail-closed recovery $(date -Is)"
        "$MANAGER" recover || true
        failures=0
        continue
      fi

      if "$MANAGER" check --quick --quiet; then
        failures=0
        continue
      fi

      failures=$((failures + 1))
      echo "health failure $failures at $(date -Is)"
      if [ "$failures" -ge 2 ]; then
        "$MANAGER" recover || true
        failures=0
      fi
    done
    ;;
  *)
    echo "usage: $0 {start|stop|status|run}" >&2
    exit 64
    ;;
esac
