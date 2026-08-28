#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPECTED='198.51.100.130'
XRAY_CONFIG='/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
SING_CONFIG='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'
MODE='quick'
QUIET=0
ERRORS=''

for arg in "$@"; do
  case "$arg" in
    --quick) MODE='quick' ;;
    --full) MODE='full' ;;
    --quiet) QUIET=1 ;;
    *) echo "usage: $0 [--quick|--full] [--quiet]" >&2; exit 64 ;;
  esac
done

add_error() {
  if [ -n "$ERRORS" ]; then
    ERRORS="$ERRORS,$1"
  else
    ERRORS="$1"
  fi
}

pgrep -f "^/usr/local/bin/xray run -c $XRAY_CONFIG$" >/dev/null 2>&1 || add_error 'xray_process'
pgrep -f "^/usr/local/bin/sing-box run -c $SING_CONFIG$" >/dev/null 2>&1 || add_error 'sing_process'
ip link show tun-vless178130 >/dev/null 2>&1 || add_error 'tun_link'
ss -lntH 2>/dev/null | grep -q '127.0.0.1:10810' || add_error 'socks_listener'
ip rule show 2>/dev/null | grep -Eq '^8999:.*to 203\.0\.113\.20 .*ipproto tcp .*dport 443 .*lookup main' || add_error 'transport_rule'
ip route get 203.0.113.20 ipproto tcp dport 443 2>/dev/null | grep -q 'dev eth0' || add_error 'transport_route'
ip route get 203.0.113.20 ipproto tcp dport 22 2>/dev/null | grep -q 'dev tun-vless178130' || add_error 'ssh_tun_route'
iptables -C OUTPUT -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || add_error 'killswitch_transport'

if [ -n "$ERRORS" ]; then
  [ "$QUIET" -eq 1 ] || echo "UNHEALTHY reasons=$ERRORS"
  exit 1
fi

MAX_TIME=10
ATTEMPTS=1
if [ "$MODE" = 'full' ]; then
  MAX_TIME=15
  ATTEMPTS=2
fi

probe_exit() {
  kind="$1"
  i=1
  while [ "$i" -le "$ATTEMPTS" ]; do
    if [ "$kind" = 'socks' ]; then
      out=$(curl -4fsS --socks5-hostname 127.0.0.1:10810 --connect-timeout 4 --max-time "$MAX_TIME" https://api.ipify.org 2>/dev/null || true)
    else
      out=$(curl -4fsS --connect-timeout 4 --max-time "$MAX_TIME" https://api.ipify.org 2>/dev/null || true)
    fi
    [ "$out" = "$EXPECTED" ] && return 0
    i=$((i + 1))
    [ "$i" -le "$ATTEMPTS" ] && sleep 1
  done
  return 1
}

probe_exit socks || add_error 'socks_exit'
probe_exit tun || add_error 'tun_exit'

if [ "$MODE" = 'full' ]; then
  timeout 12 getent ahostsv4 www.youtube.com >/dev/null 2>&1 || add_error 'dns'
  code=$(curl -4LsS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 https://www.youtube.com/generate_204 2>/dev/null || true)
  { [ "$code" = '204' ] || [ "$code" = '200' ]; } || add_error "youtube_$code"

  if curl -4fsS --interface eth0 --connect-timeout 3 --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
    add_error 'direct_eth0_leak'
  fi
fi

if [ -n "$ERRORS" ]; then
  [ "$QUIET" -eq 1 ] || echo "UNHEALTHY reasons=$ERRORS"
  exit 1
fi

[ "$QUIET" -eq 1 ] || echo "HEALTHY exit=$EXPECTED mode=$MODE checked=$(date -Is)"
