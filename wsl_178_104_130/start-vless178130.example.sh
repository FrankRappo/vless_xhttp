#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SWITCH='/usr/local/bin/switch-vless178-130-supervised'
RECOVER='/usr/local/bin/recover-vless178130'
HEALTH='/usr/local/bin/check-vless178130'
WATCHDOG='/usr/local/bin/vless178130-watchdog'
XRAY_CONFIG='/work/vpn/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
SING_CONFIG='/work/vpn/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'
STATE='/run/vless178130-switch.state'
LOCK='/run/start-vless178130.lock'
EXPECTED='198.51.100.130'

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

exec 9>"$LOCK"
flock 9

write_state() {
  umask 077
  tmp="$STATE.$$"
  printf '%s checked=%s\n' "$1" "$(date -Is)" >"$tmp"
  mv -f "$tmp" "$STATE"
}

/usr/local/bin/xray run -test -c "$XRAY_CONFIG" >/dev/null
/usr/local/bin/sing-box check -c "$SING_CONFIG" >/dev/null
bash -n "$SWITCH"
bash -n "$RECOVER"
bash -n "$HEALTH"
bash -n "$WATCHDOG"

if "$HEALTH" --quick --quiet; then
  "$WATCHDOG" start >/dev/null
  write_state "HEALTHY source=launcher exit=$EXPECTED"
  echo "Profile is healthy: exit $EXPECTED."
  "$HEALTH" --quick
  exit 0
fi

if pgrep -f "^/usr/local/bin/xray run -c $XRAY_CONFIG$" >/dev/null 2>&1 ||
   pgrep -f "^/usr/local/bin/sing-box run -c $SING_CONFIG$" >/dev/null 2>&1 ||
   ip link show tun-vless178130 >/dev/null 2>&1; then
  TARGET="$RECOVER"
  ACTION='recovery'
else
  TARGET="$SWITCH"
  ACTION='activation'
fi

service atd start >/dev/null

if pgrep -f "$TARGET" >/dev/null 2>&1; then
  echo "$ACTION is already running."
  exit 0
fi
while read -r job _; do
  [ -n "$job" ] || continue
  if at -c "$job" 2>/dev/null | grep -Fq "$TARGET"; then
    echo "$ACTION is already queued as at job $job."
    exit 0
  fi
done < <(atq)

OUT=$(printf '%s\n' "$TARGET" | at -M now 2>&1)
write_state "QUEUED action=$ACTION"
printf '%s\n' "$OUT"
echo "$ACTION queued independently through atd."
echo "State: cat $STATE"
echo "Health: sudo $HEALTH --full"
