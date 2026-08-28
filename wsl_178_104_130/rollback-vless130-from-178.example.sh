#!/bin/bash
set -euo pipefail
NEW_XRAY='/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
NEW_SING='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'
PROFILE_LOCK='/run/vless-profile.lock'

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

if [ "${VLESS_PROFILE_LOCK_HELD:-0}" != '1' ]; then
  exec 8>"$PROFILE_LOCK"
  flock 8
  export VLESS_PROFILE_LOCK_HELD=1
fi

/usr/local/bin/vless178130-watchdog stop >/dev/null 2>&1 || true
pkill -f "/usr/local/bin/sing-box run -c ${NEW_SING}" 2>/dev/null || true
pkill -f "/usr/local/bin/xray run -c ${NEW_XRAY}" 2>/dev/null || true
pkill -f "/usr/local/lib/xray/xray-26.2.6-178compat run -c ${NEW_XRAY}" 2>/dev/null || true
sleep 1
ip rule del priority 8999 2>/dev/null || true
ip route del 203.0.113.20/32 2>/dev/null || true
ip route flush cache
/usr/local/bin/start-vless130
