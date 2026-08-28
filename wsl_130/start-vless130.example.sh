#!/bin/bash
set -euo pipefail

XRAY_CONFIG="/opt/vless_xhttp/wsl_130/xray-client1-104.json"
SING_CONFIG="/opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json"
XRAY_LOG="/tmp/xray-vless130.log"
SING_LOG="/tmp/sing-vless130.log"
EXPECTED_EXIT_IP="198.51.100.130"
API_IPIFY_A="104.26.13.205"
NEW_XRAY_CONFIG="/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json"
NEW_SING_CONFIG="/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json"
PROFILE_DIR="/etc/vless-wsl"
PROFILE_FILE="${PROFILE_DIR}/profile"
PROFILE_LOCK="/run/vless-profile.lock"

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

if [ "${VLESS_PROFILE_LOCK_HELD:-0}" != "1" ]; then
  exec 8>"$PROFILE_LOCK"
  flock 8
  export VLESS_PROFILE_LOCK_HELD=1
fi

write_profile() {
  local tmp
  install -d -m 0755 "$PROFILE_DIR"
  tmp="${PROFILE_FILE}.$$"
  printf '%s\n' '104-130' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

log_tail() {
  echo "--- xray log ---" >&2
  tail -80 "$XRAY_LOG" >&2 || true
  echo "--- sing-box log ---" >&2
  tail -120 "$SING_LOG" >&2 || true
}

wait_process() {
  local pattern="$1" name="$2"
  local i
  for i in $(seq 1 15); do
    if pgrep -f "$pattern" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: $name не запустился; лог:" >&2
  log_tail
  return 1
}

warm_xray_socks() {
  local i out
  for i in $(seq 1 8); do
    if out=$(timeout 15 curl -4fsS \
      --socks5 127.0.0.1:10808 \
      --resolve "api.ipify.org:443:${API_IPIFY_A}" \
      --connect-timeout 6 --max-time 15 \
      https://api.ipify.org 2>/dev/null); then
      if [ "$out" = "$EXPECTED_EXIT_IP" ]; then
        echo "Xray SOCKS прогрет: exit IP $out"
        return 0
      fi
      echo "WARN: Xray SOCKS вернул неожиданный IP: $out" >&2
    fi
    sleep 1
  done
  echo "ERROR: Xray SOCKS не прогрелся через 104->130." >&2
  log_tail
  return 1
}

warm_tun_dns() {
  local i out
  for i in $(seq 1 10); do
    if out=$(timeout 25 curl -4fsS --connect-timeout 12 --max-time 25 https://api.ipify.org 2>/dev/null); then
      if [ "$out" = "$EXPECTED_EXIT_IP" ]; then
        echo "TUN + DNS готовы: exit IP $out"
        return 0
      fi
      echo "WARN: TUN вернул неожиданный IP: $out" >&2
    fi
    sleep 2
  done
  echo "ERROR: TUN/DNS не поднялись до рабочего состояния." >&2
  log_tail
  return 1
}

/usr/local/bin/vless178130-watchdog stop >/dev/null 2>&1 || true
pkill -f "/usr/local/bin/sing-box run -c ${NEW_SING_CONFIG}" 2>/dev/null || true
pkill -f "/usr/local/bin/xray run -c ${NEW_XRAY_CONFIG}" 2>/dev/null || true
ip rule del priority 8999 2>/dev/null || true
ip route del 203.0.113.20/32 2>/dev/null || true
ip route flush cache

/usr/local/bin/killswitch-vless-104
pkill -f "/usr/local/bin/sing-box run -c ${SING_CONFIG}" 2>/dev/null || true
pkill -f "/usr/local/bin/xray run -c ${XRAY_CONFIG}" 2>/dev/null || true
sleep 1
rm -f "$XRAY_LOG" "$SING_LOG" /tmp/xray-vless130.pid /tmp/sing-vless130.pid

nohup /usr/local/bin/xray run -c "$XRAY_CONFIG" > "$XRAY_LOG" 2>&1 8>&- 9>&- & echo $! > /tmp/xray-vless130.pid
wait_process "/usr/local/bin/xray run -c ${XRAY_CONFIG}" "xray"
warm_xray_socks

nohup /usr/local/bin/sing-box run -c "$SING_CONFIG" > "$SING_LOG" 2>&1 8>&- 9>&- & echo $! > /tmp/sing-vless130.pid
wait_process "/usr/local/bin/sing-box run -c ${SING_CONFIG}" "sing-box"
sleep 1
warm_tun_dns
write_profile

getent hosts entry.example.com
printf 'xray pid file: '; cat /tmp/xray-vless130.pid
printf 'sing-box pid file: '; cat /tmp/sing-vless130.pid
echo "Запущено и проверено: WSL -> 104 -> 130, DNS через туннель, exit IP ${EXPECTED_EXIT_IP}."
echo "Проверка IP: curl -4 --max-time 15 -sS https://api.ipify.org ; echo"
