#!/bin/bash
set -u
LOG=/var/log/vless130-boot.log
EXPECTED_EXIT=198.51.100.130
PROFILE_FILE=/etc/vless-wsl/profile
PROFILE_LOCK=/run/vless-profile.lock
mkdir -p /var/log
exec 9>"$PROFILE_LOCK"
if ! flock -n 9; then
  exit 0
fi

selected_profile() {
  if [ -r "$PROFILE_FILE" ]; then
    tr -d '[:space:]' <"$PROFILE_FILE"
  else
    printf '%s' '104-130'
  fi
}

profile_is_running() {
  pgrep -f '/usr/local/bin/xray run -c /opt/vless_xhttp/wsl_130/xray-client1-104.json' >/dev/null &&
  pgrep -f '/usr/local/bin/sing-box run -c /opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json' >/dev/null
}
exit_is_correct() {
  local out
  out=$(curl -4fsS --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null) || return 1
  [ "$out" = "$EXPECTED_EXIT" ]
}
exec >>"$LOG" 2>&1
PROFILE=$(selected_profile)

case "$PROFILE" in
  104-130)
    if profile_is_running && exit_is_correct; then
      exit 0
    fi
    printf '\n[%s] WSL VPN recovery started profile=104-130\n' "$(date -Is)"
    for attempt in 1 2 3; do
      echo "start attempt $attempt/3"
      if VLESS_PROFILE_LOCK_HELD=1 /usr/local/bin/start-vless130 && exit_is_correct; then
        echo "startup verified: profile=104-130 exit=$EXPECTED_EXIT"
        exit 0
      fi
      echo "attempt $attempt failed; retrying in 15 seconds"
      sleep 15
    done
    echo 'ERROR: profile 104-130 did not become healthy; killswitch remains fail-closed'
    exit 1
    ;;
  178-104-130)
    if /usr/local/bin/check-vless178130 --quick --quiet; then
      env -u VLESS_PROFILE_LOCK_HELD /usr/local/bin/vless178130-watchdog start >/dev/null 2>&1 || true
      exit 0
    fi
    printf '\n[%s] WSL VPN recovery queued profile=178-104-130\n' "$(date -Is)"
    /usr/local/bin/killswitch-vless-178
    /usr/local/bin/start-vless178130
    ;;
  *)
    printf '\n[%s] ERROR: invalid selected profile: %s\n' "$(date -Is)" "$PROFILE"
    /usr/local/bin/killswitch-vless-104
    echo 'No VPN profile started; firewall remains fail-closed.'
    exit 64
    ;;
esac
