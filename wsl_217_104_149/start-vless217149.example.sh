#!/bin/bash
# Start profile 217-104-149 (Relay 217 -> 104 -> 149)
set -uo pipefail
XRAY_CFG='<path-to>/xray-wsl-217-104-149.json'
SING_CFG='<path-to>/sing-box-tun-217-104-149.json'
EXPECTED='<expected-exit-ip>'
TUN='tun-vless217149'

[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"

# Stop old processes
pkill -f "xray run -c $XRAY_CFG" 2>/dev/null || true
pkill -f "sing-box run -c $SING_CFG" 2>/dev/null || true

# Apply killswitch (fail-closed)
/usr/local/bin/killswitch-vless-217

# Start xray + sing-box
nohup /usr/local/bin/xray run -c "$XRAY_CFG" 8>&- 9>&- >/var/log/vless217-149-xray.log 2>&1 &
sleep 1
nohup /usr/local/bin/sing-box run -c "$SING_CFG" 8>&- 9>&- >/var/log/vless217-149-sing.log 2>&1 &

# Warm-up: verify exit IP
for _ in $(seq 1 45); do
  ip link show "$TUN" >/dev/null 2>&1 || { sleep 1; continue; }
  out=$(curl -4fsS --connect-timeout 5 --max-time 12 https://api.ipify.org 2>/dev/null || true)
  if [ "$out" = "$EXPECTED" ]; then
    echo "HEALTHY profile=217-104-149 exit=$EXPECTED fail_closed=yes"
    /usr/local/bin/vless217-watchdog start 8>&- 9>&- >/dev/null 2>&1 || true
    exit 0
  fi
  sleep 1
done
echo "ERROR: fail-closed rules remain active" >&2
exit 1
