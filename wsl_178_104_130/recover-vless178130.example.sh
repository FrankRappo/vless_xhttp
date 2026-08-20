#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

D='/work/vpn/vless_xhttp/wsl_178_104_130'
XRAY_CONFIG="$D/xray-wsl-178-104-130.json"
SING_CONFIG="$D/sing-box-tun-178-104-130.json"
XRAY_PID='/run/xray-vless178130.pid'
SING_PID='/run/sing-vless178130.pid'
XRAY_LOG='/tmp/xray-vless178130.log'
SING_LOG='/tmp/sing-vless178130.log'
LOG='/tmp/vless178130-recovery.log'
STATE='/run/vless178130-switch.state'
LOCK='/run/vless178130-recovery.lock'
EXPECTED='198.51.100.130'
TOUCHED=0

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Recovery is already running."
  exit 0
fi
exec >>"$LOG" 2>&1

write_state() {
  umask 077
  tmp="$STATE.$$"
  printf '%s checked=%s\n' "$1" "$(date -Is)" >"$tmp"
  mv -f "$tmp" "$STATE"
}

stop_exact() {
  pidfile="$1"
  pattern="$2"
  if [ -s "$pidfile" ]; then
    start-stop-daemon --stop --oknodo --retry=TERM/5/KILL/2 --pidfile "$pidfile" --remove-pidfile || true
  fi
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    for n in 1 2 3 4 5; do
      pgrep -f "$pattern" >/dev/null 2>&1 || break
      sleep 1
    done
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

start_xray() {
  : >"$XRAY_LOG"
  start-stop-daemon --start --background --make-pidfile --pidfile "$XRAY_PID" --startas /usr/local/bin/xray --output "$XRAY_LOG" -- run -c "$XRAY_CONFIG"
  for n in $(seq 1 20); do
    if start-stop-daemon --status --pidfile "$XRAY_PID" >/dev/null 2>&1 && ss -lntH | grep -q '127.0.0.1:10810'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_sing() {
  : >"$SING_LOG"
  start-stop-daemon --start --background --make-pidfile --pidfile "$SING_PID" --startas /usr/local/bin/sing-box --output "$SING_LOG" -- run -c "$SING_CONFIG"
  for n in $(seq 1 20); do
    if start-stop-daemon --status --pidfile "$SING_PID" >/dev/null 2>&1 && ip link show tun-vless178130 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

rollback() {
  original_rc="$1"
  trap - ERR
  set +e
  echo "recovery failure rc=$original_rc; rolling back at $(date -Is)"
  write_state "RECOVERY_FAILED rc=$original_rc action=rollback"
  stop_exact "$XRAY_PID" "^/usr/local/bin/xray run -c $XRAY_CONFIG$"
  stop_exact "$SING_PID" "^/usr/local/bin/sing-box run -c $SING_CONFIG$"
  if /usr/local/bin/rollback-vless130-from-178; then
    write_state "ROLLED_BACK from=178 reason=recovery_failed"
  else
    rollback_rc=$?
    write_state "ROLLBACK_FAILED recovery_rc=$original_rc rollback_rc=$rollback_rc"
  fi
  exit "$original_rc"
}

on_error() {
  rc=$?
  line="$1"
  echo "ERROR rc=$rc line=$line at $(date -Is)"
  rollback "$rc"
}
trap 'on_error $LINENO' ERR

echo "RECOVERY START pid=$$ at $(date -Is)"
write_state 'RECOVERING action=local_xray'

if /usr/local/bin/check-vless178130 --quick --quiet; then
  write_state "HEALTHY source=recovery-noop exit=$EXPECTED"
  /usr/local/bin/vless178130-watchdog start >/dev/null
  echo "already healthy"
  trap - ERR
  exit 0
fi

/usr/local/bin/xray run -test -c "$XRAY_CONFIG" >/dev/null
/usr/local/bin/sing-box check -c "$SING_CONFIG" >/dev/null
bash -n /usr/local/bin/check-vless178130
bash -n /usr/local/bin/vless178130-watchdog

if ! iptables -C OUTPUT -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1; then
  /usr/local/bin/killswitch-vless-178
fi
GW=$(ip route show default dev eth0 | awk '/default/{print $3; exit}')
[ -n "$GW" ]
ip route replace 203.0.113.20/32 via "$GW" dev eth0
ip rule show | grep -q '^8999:' || ip rule add priority 8999 to 203.0.113.20/32 lookup main
ip route flush cache

TOUCHED=1
stop_exact "$XRAY_PID" "^/usr/local/bin/xray run -c $XRAY_CONFIG$"
start_xray

SOCKS=''
for n in 1 2 3 4 5; do
  SOCKS=$(curl -4fsS --socks5-hostname 127.0.0.1:10810 --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)
  [ "$SOCKS" = "$EXPECTED" ] && break
  sleep 2
done
[ "$SOCKS" = "$EXPECTED" ]
write_state "RECOVERING stage=xray_ok exit=$SOCKS"

if ! /usr/local/bin/check-vless178130 --quick --quiet; then
  echo "TUN did not recover after Xray restart; restarting sing-box."
  stop_exact "$SING_PID" "^/usr/local/bin/sing-box run -c $SING_CONFIG$"
  start_sing
fi

for n in 1 2 3; do
  /usr/local/bin/check-vless178130 --quick --quiet && break
  sleep 3
done
/usr/local/bin/check-vless178130 --full
write_state "HEALTHY source=recovery exit=$EXPECTED"
trap - ERR
/usr/local/bin/vless178130-watchdog start >/dev/null
echo "RECOVERY SUCCESS at $(date -Is)"
