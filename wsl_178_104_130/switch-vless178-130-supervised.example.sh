#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
D='/work/vpn/vless_xhttp/wsl_178_104_130'
NEW_XRAY="$D/xray-wsl-178-104-130.json"
NEW_SING="$D/sing-box-tun-178-104-130.json"
XRAY_BIN='/usr/local/bin/xray'
OLD_XRAY='/work/vpn/vless_xhttp/wsl_130/xray-client1-104.json'
OLD_SING='/work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
LOG='/tmp/vless178130-switch.log'
STATE='/run/vless178130-switch.state'
XRAY_LOG='/tmp/xray-vless178130.log'
SING_LOG='/tmp/sing-vless178130.log'
XRAY_PID='/run/xray-vless178130.pid'
SING_PID='/run/sing-vless178130.pid'
EXPECTED='198.51.100.130'
COMMITTED=0
exec >>"$LOG" 2>&1
echo "START $(date -Is) pid=$$" >"$STATE"
echo "supervisor start $(date -Is)"
fail() {
  rc=$?
  line=$1
  trap - ERR
  set +e
  echo "FAILED rc=$rc line=$line $(date -Is)" | tee "$STATE"
  if [ "$COMMITTED" -eq 1 ]; then
    echo "Committed switch failed; restoring WSL -> 104 -> 130."
    if /usr/local/bin/rollback-vless130-from-178; then
      echo "ROLLED_BACK original_rc=$rc line=$line $(date -Is)" | tee "$STATE"
    else
      rollback_rc=$?
      echo "ROLLBACK_FAILED original_rc=$rc rollback_rc=$rollback_rc line=$line $(date -Is)" | tee "$STATE"
    fi
  else
    if [ -s "$XRAY_PID" ]; then
      start-stop-daemon --stop --oknodo --retry=TERM/5/KILL/2 --pidfile "$XRAY_PID" --remove-pidfile || true
    fi
    pkill -f "${XRAY_BIN} run -c ${NEW_XRAY}" 2>/dev/null || true
    iptables -D OUTPUT -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -i eth0 -s 203.0.113.20 -p tcp --sport 443 -j ACCEPT 2>/dev/null || true
    ip rule del priority 8999 2>/dev/null || true
    ip route del 203.0.113.20/32 2>/dev/null || true
    ip route flush cache
  fi
  exit "$rc"
}
trap 'fail $LINENO' ERR

# Add temporary direct permission while the old VPN remains active.
iptables -C OUTPUT -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
  iptables -I OUTPUT 4 -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT
iptables -C INPUT -i eth0 -s 203.0.113.20 -p tcp --sport 443 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 4 -i eth0 -s 203.0.113.20 -p tcp --sport 443 -j ACCEPT
GW=$(ip route show default dev eth0 | awk '/default/{print $3;exit}')
ip route replace 203.0.113.20/32 via "$GW" dev eth0
ip rule add priority 8999 to 203.0.113.20/32 lookup main 2>/dev/null || true
ip route flush cache

# Preflight Xray runs beside the old chain on a distinct SOCKS port.
if [ -s "$XRAY_PID" ]; then
  start-stop-daemon --stop --oknodo --retry=TERM/5/KILL/2 --pidfile "$XRAY_PID" --remove-pidfile || true
fi
pkill -f "${XRAY_BIN} run -c ${NEW_XRAY}" 2>/dev/null || true
rm -f "$XRAY_PID"
: >"$XRAY_LOG"
start-stop-daemon --start --background --make-pidfile --pidfile "$XRAY_PID" --startas "$XRAY_BIN" --output "$XRAY_LOG" -- run -c "$NEW_XRAY"
for _ in $(seq 1 20); do ss -lntH | grep -q '127.0.0.1:10810' && break; sleep 1; done
ss -lntH | grep -q '127.0.0.1:10810'
PRE=''
for _ in $(seq 1 10); do
  PRE=$(curl -4fsS --socks5 127.0.0.1:10810 --resolve api.ipify.org:443:104.26.13.205 --connect-timeout 10 --max-time 25 https://api.ipify.org 2>/dev/null || true)
  [ "$PRE" = "$EXPECTED" ] && break
  sleep 2
done
[ "$PRE" = "$EXPECTED" ]
echo "PREFLIGHT_OK exit=$PRE $(date -Is)" | tee "$STATE"

# Commit the transport change. This script belongs to atd, not to the network session.
COMMITTED=1
/usr/local/bin/killswitch-vless-178
pkill -f "/usr/local/bin/sing-box run -c ${OLD_SING}" 2>/dev/null || true
pkill -f "/usr/local/bin/sing-box run -c ${NEW_SING}" 2>/dev/null || true
pkill -f "/usr/local/bin/xray run -c ${OLD_XRAY}" 2>/dev/null || true
sleep 1
rm -f "$SING_PID"
: >"$SING_LOG"
start-stop-daemon --start --background --make-pidfile --pidfile "$SING_PID" --startas /usr/local/bin/sing-box --output "$SING_LOG" -- run -c "$NEW_SING"
for _ in $(seq 1 20); do ip link show tun-vless178130 >/dev/null 2>&1 && break; sleep 1; done
ip link show tun-vless178130 >/dev/null
FINAL=''
for _ in $(seq 1 12); do
  FINAL=$(curl -4fsS --connect-timeout 12 --max-time 30 https://api.ipify.org 2>/dev/null || true)
  [ "$FINAL" = "$EXPECTED" ] && break
  sleep 2
done
[ "$FINAL" = "$EXPECTED" ]
# A failed direct-eth0 request is the expected, successful leak-test result.
# Keep the command in an if condition so the global ERR trap does not fire.
if curl -4fsS --interface eth0 --connect-timeout 4 --max-time 6 https://api.ipify.org >/tmp/vless178130-direct-test.out 2>&1; then
  DIRECT_RC=0
else
  DIRECT_RC=$?
fi
[ "$DIRECT_RC" -ne 0 ]
curl -4fsS -o /dev/null --connect-timeout 12 --max-time 35 https://www.youtube.com/
echo "SUCCESS exit=$FINAL direct_rc=$DIRECT_RC $(date -Is)" | tee "$STATE"
/usr/local/bin/vless178130-watchdog start
trap - ERR
