#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG='/etc/openvpn/client/194_130wsl-over-ssh.conf'
PIDFILE='/run/openvpn-wsl-ssh.pid'
LOG='/var/log/openvpn-wsl-ssh.log'
EXPECTED_EXIT='198.51.100.130'
XRAY_104='/opt/vless_xhttp/wsl_130/xray-client1-104.json'
SING_104='/opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
XRAY_178='/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
SING_178='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

read_endpoint() {
  read -r _ ENDPOINT_IP ENDPOINT_PORT < <(awk '$1 == "remote" { print; exit }' "$CONFIG")
  if [ -z "${ENDPOINT_IP:-}" ] || [ -z "${ENDPOINT_PORT:-}" ]; then
    echo "ERROR: remote endpoint not found in $CONFIG" >&2
    exit 64
  fi
}

openvpn_running() {
  pgrep -f "^/usr/sbin/openvpn --config ${CONFIG} " >/dev/null 2>&1
}

clear_firewall() {
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  iptables -X 2>/dev/null || true
  ip6tables -P INPUT ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -P OUTPUT ACCEPT
  ip6tables -F
  ip6tables -X 2>/dev/null || true
}

apply_firewall() {
  local v4 v6
  v4=$(mktemp)
  v6=$(mktemp)
  cat >"$v4" <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -i tun+ -j ACCEPT
-A INPUT -i eth0 -s ${ENDPOINT_IP}/32 -p tcp --sport ${ENDPOINT_PORT} -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -o eth0 -d ${ENDPOINT_IP}/32 -p tcp --dport ${ENDPOINT_PORT} -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
RULES
  cat >"$v6" <<'RULES'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
RULES
  iptables-restore --test <"$v4"
  ip6tables-restore --test <"$v6"
  iptables-restore <"$v4"
  ip6tables-restore <"$v6"
  rm -f "$v4" "$v6"
}

assert_firewall() {
  [ "$(iptables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  [ "$(ip6tables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  iptables -C OUTPUT -o eth0 -d "$ENDPOINT_IP" -p tcp --dport "$ENDPOINT_PORT" -j ACCEPT
}

stop_vless() {
  /usr/local/bin/vless178130-watchdog stop >/dev/null 2>&1 || true
  pgrep -f "^/usr/local/bin/sing-box run -c ${SING_104}$" | xargs -r kill || true
  pgrep -f "^/usr/local/bin/xray run -c ${XRAY_104}$" | xargs -r kill || true
  pgrep -f "^/usr/local/bin/sing-box run -c ${SING_178}$" | xargs -r kill || true
  pgrep -f "^/usr/local/bin/xray run -c ${XRAY_178}$" | xargs -r kill || true
  ip rule del priority 8999 2>/dev/null || true
  ip route del 203.0.113.20/32 2>/dev/null || true
  ip route flush cache
}

check_profile() {
  local out
  openvpn_running
  ip link show tun0 >/dev/null 2>&1
  ip route get 1.1.1.1 | grep -q 'dev tun0'
  assert_firewall
  out=$(curl -4fsS --connect-timeout 8 --max-time 20 https://api.ipify.org)
  if [ "$out" != "$EXPECTED_EXIT" ]; then
    echo "ERROR: expected exit $EXPECTED_EXIT, got ${out:-unavailable}" >&2
    return 1
  fi
  if curl -4fsS --interface eth0 --resolve api.ipify.org:443:104.26.13.205 --connect-timeout 3 --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: direct eth0 leak detected' >&2
    return 1
  fi
  echo "HEALTHY profile=openvpn-ssh-194-130 exit=$EXPECTED_EXIT fail_closed=yes"
}

start_profile() {
  read_endpoint
  stop_vless
  apply_firewall

  if ! openvpn_running; then
    rm -f "$PIDFILE"
    touch "$LOG"
    /usr/sbin/openvpn --config "$CONFIG" --daemon openvpn-wsl-ssh --writepid "$PIDFILE" --log-append "$LOG"
  fi

  for _ in $(seq 1 40); do
    if ip link show tun0 >/dev/null 2>&1 && ip route get 1.1.1.1 | grep -q 'dev tun0'; then
      check_profile
      return
    fi
    sleep 1
  done

  echo 'ERROR: OpenVPN did not become healthy; fail-closed rules remain active.' >&2
  tail -80 "$LOG" >&2 || true
  return 1
}

stop_profile() {
  pgrep -f "^/usr/sbin/openvpn --config ${CONFIG} " | xargs -r kill || true
  for _ in $(seq 1 10); do
    openvpn_running || break
    sleep 1
  done
  rm -f "$PIDFILE"
  clear_firewall
  echo 'STOPPED profile=openvpn-ssh-194-130 firewall=normal'
}

show_status() {
  local process='stopped' tun='none' route='direct' firewall='normal'
  openvpn_running && process='running' || true
  ip link show tun0 >/dev/null 2>&1 && tun='tun0' || true
  ip route get 1.1.1.1 2>/dev/null | grep -q 'dev tun0' && route='tun0' || true
  [ "$(iptables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ] && firewall='fail-closed' || true
  printf 'profile=openvpn-ssh-194-130\nprocess=%s\ntun=%s\nroute=%s\nfirewall=%s\n' "$process" "$tun" "$route" "$firewall"
}

case "${1:-status}" in
  start) start_profile ;;
  stop) stop_profile ;;
  restart) stop_profile; start_profile ;;
  status) show_status ;;
  check) read_endpoint; check_profile ;;
  *)
    echo 'usage: openvpn-wsl {start|stop|restart|status|check}' >&2
    exit 64
    ;;
esac
