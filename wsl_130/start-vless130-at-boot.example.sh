#!/bin/bash
set -u
LOG=/var/log/vless130-boot.log
EXPECTED_EXIT=198.51.100.130
mkdir -p /var/log
exec 9>/run/vless130-boot.lock
if ! flock -n 9; then
  exit 0
fi
profile_is_running() {
  pgrep -f '/usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_130/xray-client1-104.json' >/dev/null &&
  pgrep -f '/usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json' >/dev/null
}
exit_is_correct() {
  local out
  out=$(curl -4fsS --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null) || return 1
  [ "$out" = "$EXPECTED_EXIT" ]
}
if profile_is_running && exit_is_correct; then
  exit 0
fi
exec >>"$LOG" 2>&1
printf '\n[%s] WSL VPN recovery started\n' "$(date -Is)"
for attempt in 1 2 3; do
  echo "start attempt $attempt/3"
  if /usr/local/bin/start-vless130 && exit_is_correct; then
    echo "startup verified: exit $EXPECTED_EXIT"
    exit 0
  fi
  echo "attempt $attempt failed; retrying in 15 seconds"
  sleep 15
done
echo 'ERROR: WSL VPN did not become healthy; killswitch remains fail-closed'
exit 1
