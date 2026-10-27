#!/bin/bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF='/usr/local/bin/vless104130-ssh'
WATCHDOG='/usr/local/bin/vless104130-ssh-watchdog'
KILLSWITCH='/usr/local/bin/killswitch-vless-104-ssh'
SOURCE_XRAY='/opt/vless_xhttp/wsl_130/xray-client1-104.json'
SOURCE_SING='/opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
OLD_XRAY='/opt/vless_xhttp/wsl_130/xray-client1-104.json'
OLD_SING='/opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
NEW_XRAY='/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
NEW_SING='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'
RUNTIME_DIR='/run/vless104130-ssh'
XRAY_CONFIG="$RUNTIME_DIR/xray.json"
SING_CONFIG="$RUNTIME_DIR/sing-box.json"
SSH_KEY='/etc/vless-wsl/ssh104130_ed25519'
KNOWN_HOSTS='/etc/vless-wsl/known_hosts'
SSH_PID="$RUNTIME_DIR/ssh.pid"
XRAY_PID="$RUNTIME_DIR/xray.pid"
SING_PID="$RUNTIME_DIR/sing-box.pid"
SSH_LOG="$RUNTIME_DIR/ssh.log"
XRAY_LOG="$RUNTIME_DIR/xray.log"
SING_LOG="$RUNTIME_DIR/sing-box.log"
ENABLED='/run/vless104130-ssh.enabled'
LOCK='/run/vless104130-ssh.lock'
PROFILE_LOCK='/run/vless-profile.lock'
PROFILE_FILE='/etc/vless-wsl/profile'
ENTRY_IP='203.0.113.10'
ENTRY_SSH_PORT=22
FORWARD_PORT=18443
SOCKS_PORT=18130
TUN_NAME='tun-vlessssh130'
TUN_ADDRESS='172.19.131.1/30'
EXPECTED_EXIT='198.51.100.130'
API_IPIFY_A='104.26.13.205'

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

acquire_locks() {
  if [ "${VLESS_PROFILE_LOCK_HELD:-0}" != '1' ]; then
    exec 8>"$PROFILE_LOCK"
    flock 8
    export VLESS_PROFILE_LOCK_HELD=1
  fi
  exec 9>"$LOCK"
  flock 9
}

process_from_pidfile() {
  local pidfile="$1" needle="$2" pid cmd
  [ -s "$pidfile" ] || return 1
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
  [[ "$cmd" == *"$needle"* ]]
}

ssh_running() {
  process_from_pidfile "$SSH_PID" "$SSH_KEY"
}

xray_running() {
  process_from_pidfile "$XRAY_PID" "$XRAY_CONFIG"
}

sing_running() {
  process_from_pidfile "$SING_PID" "$SING_CONFIG"
}

stop_pidfile() {
  local pidfile="$1" needle="$2" pid cmd
  [ -s "$pidfile" ] || return 0
  pid=$(cat "$pidfile")
  if [ ! -r "/proc/$pid/cmdline" ]; then
    rm -f "$pidfile"
    return 0
  fi
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
  if [[ "$cmd" != *"$needle"* ]]; then
    rm -f "$pidfile"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$pidfile"
}

stop_runtime() {
  stop_pidfile "$SING_PID" "$SING_CONFIG"
  stop_pidfile "$XRAY_PID" "$XRAY_CONFIG"
  stop_pidfile "$SSH_PID" "$SSH_KEY"
  pkill -f "^/usr/local/bin/sing-box run -c $SING_CONFIG$" 2>/dev/null || true
  pkill -f "^/usr/local/bin/xray run -c $XRAY_CONFIG$" 2>/dev/null || true
  ip route del "$ENTRY_IP/32" 2>/dev/null || true
  ip route flush cache
}

stop_other_profiles() {
  if [ -x /usr/local/bin/openvpn-wsl ]; then
    if ! /usr/local/bin/openvpn-wsl quiesce >/dev/null 2>&1; then
      pkill -f '^/usr/sbin/openvpn --config /etc/openvpn/client/194_130wsl-over-ssh.conf ' 2>/dev/null || true
      rm -f /run/openvpn-wsl.enabled /run/openvpn-wsl-ssh.pid
    fi
  fi
  /usr/local/bin/vless178130-watchdog stop >/dev/null 2>&1 || true
  pkill -f "^/usr/local/bin/sing-box run -c $OLD_SING$" 2>/dev/null || true
  pkill -f "^/usr/local/bin/xray run -c $OLD_XRAY$" 2>/dev/null || true
  pkill -f "^/usr/local/bin/sing-box run -c $NEW_SING$" 2>/dev/null || true
  pkill -f "^/usr/local/bin/xray run -c $NEW_XRAY$" 2>/dev/null || true
  ip rule del priority 8999 2>/dev/null || true
  ip route del 203.0.113.20/32 2>/dev/null || true
  ip route flush cache
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

write_profile() {
  local tmp
  install -d -m 0755 "$(dirname "$PROFILE_FILE")"
  tmp="${PROFILE_FILE}.$$"
  printf '%s\n' '104-130-over-ssh' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

assert_ssh_material() {
  local key_owner_mode hosts_owner_mode
  [ -r "$SSH_KEY" ]
  [ -r "$KNOWN_HOSTS" ]
  key_owner_mode=$(stat -c '%u:%a' "$SSH_KEY")
  hosts_owner_mode=$(stat -c '%u:%a' "$KNOWN_HOSTS")
  [ "$key_owner_mode" = '0:600' ] || {
    echo "ERROR: $SSH_KEY must be owned by root with mode 0600" >&2
    return 1
  }
  case "$hosts_owner_mode" in
    0:600|0:644) ;;
    *)
      echo "ERROR: $KNOWN_HOSTS must be root-owned and not writable by group/others" >&2
      return 1
      ;;
  esac
  ssh-keygen -F "$ENTRY_IP" -f "$KNOWN_HOSTS" >/dev/null
}

generate_configs() {
  install -d -m 0700 "$RUNTIME_DIR"
  umask 077
  python3 - "$SOURCE_XRAY" "$XRAY_CONFIG" "$SOURCE_SING" "$SING_CONFIG" \
    "$ENTRY_IP" "$ENTRY_SSH_PORT" "$FORWARD_PORT" "$SOCKS_PORT" "$TUN_NAME" "$TUN_ADDRESS" <<'PY'
import json
import sys

(xray_source, xray_target, sing_source, sing_target, entry_ip,
 ssh_port, forward_port, socks_port, tun_name, tun_address) = sys.argv[1:]
ssh_port = int(ssh_port)
forward_port = int(forward_port)
socks_port = int(socks_port)

with open(xray_source, encoding="utf-8") as fh:
    xray = json.load(fh)

socks_inbounds = [item for item in xray.get("inbounds", []) if item.get("protocol") == "socks"]
if len(socks_inbounds) != 1:
    raise SystemExit("expected exactly one Xray SOCKS inbound")
socks_inbounds[0]["listen"] = "127.0.0.1"
socks_inbounds[0]["port"] = socks_port

vless_outbounds = [item for item in xray.get("outbounds", []) if item.get("protocol") == "vless"]
if len(vless_outbounds) != 1:
    raise SystemExit("expected exactly one Xray VLESS outbound")
vnext = vless_outbounds[0].get("settings", {}).get("vnext", [])
if len(vnext) != 1:
    raise SystemExit("expected exactly one Xray VLESS destination")
vnext[0]["address"] = "127.0.0.1"
vnext[0]["port"] = forward_port

with open(xray_target, "w", encoding="utf-8") as fh:
    json.dump(xray, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

with open(sing_source, encoding="utf-8") as fh:
    sing = json.load(fh)

tun_inbounds = [item for item in sing.get("inbounds", []) if item.get("type") == "tun"]
if len(tun_inbounds) != 1:
    raise SystemExit("expected exactly one sing-box TUN inbound")
tun_inbounds[0]["interface_name"] = tun_name
tun_inbounds[0]["address"] = [tun_address]

socks_outbounds = [item for item in sing.get("outbounds", []) if item.get("type") == "socks"]
if len(socks_outbounds) != 1:
    raise SystemExit("expected exactly one sing-box SOCKS outbound")
socks_outbounds[0]["server"] = "127.0.0.1"
socks_outbounds[0]["server_port"] = socks_port

route = sing.setdefault("route", {})
rules = route.setdefault("rules", [])
rules[:] = [
    rule for rule in rules
    if not (rule.get("outbound") == "direct" and entry_ip + "/32" in rule.get("ip_cidr", []))
]
rules.append({
    "ip_cidr": [entry_ip + "/32"],
    "port": ssh_port,
    "network": ["tcp"],
    "outbound": "direct",
})

with open(sing_target, "w", encoding="utf-8") as fh:
    json.dump(sing, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  chmod 0600 "$XRAY_CONFIG" "$SING_CONFIG"
  /usr/local/bin/xray run -test -c "$XRAY_CONFIG" >/dev/null
  /usr/local/bin/sing-box check -c "$SING_CONFIG" >/dev/null
}

wait_for_listener() {
  local port="$1" name="$2"
  for _ in $(seq 1 40); do
    if ss -lntH | grep -qE "127\\.0\\.0\\.1:${port}([[:space:]]|$)"; then
      return 0
    fi
    sleep 0.25
  done
  echo "ERROR: $name did not listen on 127.0.0.1:$port" >&2
  return 1
}

base_exit() {
  curl -4fsS --socks5 "127.0.0.1:$SOCKS_PORT" \
    --resolve "api.ipify.org:443:$API_IPIFY_A" \
    --connect-timeout 8 --max-time 20 https://api.ipify.org
}

assert_firewall() {
  [ "$(iptables -S INPUT | head -n 1)" = '-P INPUT DROP' ]
  [ "$(iptables -S FORWARD | head -n 1)" = '-P FORWARD DROP' ]
  [ "$(iptables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  [ "$(ip6tables -S INPUT | head -n 1)" = '-P INPUT DROP' ]
  [ "$(ip6tables -S FORWARD | head -n 1)" = '-P FORWARD DROP' ]
  [ "$(ip6tables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  iptables -C OUTPUT -o eth0 -d "$ENTRY_IP" -p tcp --dport "$ENTRY_SSH_PORT" -j ACCEPT
  iptables -C INPUT -i eth0 -s "$ENTRY_IP" -p tcp --sport "$ENTRY_SSH_PORT" -j ACCEPT
  ! iptables -C OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1
  ! iptables -C INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1
  local unexpected
  unexpected=$(iptables -S OUTPUT | awk -v target="$ENTRY_IP/32" -v port="$ENTRY_SSH_PORT" '
    $1 == "-A" && $2 == "OUTPUT" && /-o eth0/ && /-j ACCEPT/ &&
      (index($0, "-d " target) == 0 || index($0, "--dport " port) == 0) { print }
  ')
  [ -z "$unexpected" ] || {
    echo "ERROR: unexpected direct eth0 allow: $unexpected" >&2
    return 1
  }
}

assert_no_direct_leak() {
  if curl -4fsS --interface eth0 --resolve "api.ipify.org:443:$API_IPIFY_A" \
      --connect-timeout 3 --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: direct eth0 HTTPS leak detected' >&2
    return 1
  fi
  if curl -4fsS --interface eth0 --connect-timeout 3 --max-time 5 \
      telnet://1.1.1.1:53 </dev/null >/dev/null 2>&1; then
    echo 'ERROR: direct eth0 TCP/53 leak detected' >&2
    return 1
  fi
  if curl -6fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: IPv6 leak detected' >&2
    return 1
  fi
}

check_profile() {
  local mode='full' quiet=0 out current
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --quick) mode='quick' ;;
      --full) mode='full' ;;
      --quiet) quiet=1 ;;
      *) echo "unknown check option: $1" >&2; return 64 ;;
    esac
    shift
  done
  ssh_running
  xray_running
  sing_running
  ip link show "$TUN_NAME" >/dev/null 2>&1
  wait_for_listener "$FORWARD_PORT" 'SSH forward'
  wait_for_listener "$SOCKS_PORT" 'Xray SOCKS'
  assert_firewall
  ip route get "$ENTRY_IP" | grep -q "dev eth0"
  out=$(base_exit)
  [ "$out" = "$EXPECTED_EXIT" ] || {
    echo "ERROR: expected base exit $EXPECTED_EXIT, got ${out:-unavailable}" >&2
    return 1
  }
  if [ "$mode" = 'full' ]; then
    assert_no_direct_leak
  fi
  if [ "$quiet" -eq 0 ]; then
    current=$(curl -4fsS --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || printf unavailable)
    printf 'HEALTHY profile=104-130-over-ssh base_exit=%s current_exit=%s fail_closed=yes\n' "$out" "$current"
  fi
}

start_runtime() {
  local gateway out
  [ -r "$SOURCE_XRAY" ]
  [ -r "$SOURCE_SING" ]
  assert_ssh_material
  generate_configs
  stop_runtime
  gateway=$(ip -4 route show default | awk '$1 == "default" && $5 == "eth0" { print $3; exit }')
  [ -n "$gateway" ] || {
    echo 'ERROR: cannot determine the WSL eth0 gateway' >&2
    return 1
  }
  ip route replace "$ENTRY_IP/32" via "$gateway" dev eth0

  : >"$SSH_LOG"
  nohup /usr/bin/ssh -N -T \
    -i "$SSH_KEY" -p "$ENTRY_SSH_PORT" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -L "127.0.0.1:${FORWARD_PORT}:127.0.0.1:443" \
    "root@$ENTRY_IP" >"$SSH_LOG" 2>&1 8>&- 9>&- &
  echo $! >"$SSH_PID"
  wait_for_listener "$FORWARD_PORT" 'SSH forward'
  ssh_running

  : >"$XRAY_LOG"
  nohup /usr/local/bin/xray run -c "$XRAY_CONFIG" >"$XRAY_LOG" 2>&1 8>&- 9>&- &
  echo $! >"$XRAY_PID"
  wait_for_listener "$SOCKS_PORT" 'Xray SOCKS'
  xray_running
  out=$(base_exit)
  [ "$out" = "$EXPECTED_EXIT" ] || {
    echo "ERROR: Xray-over-SSH returned ${out:-unavailable}, expected $EXPECTED_EXIT" >&2
    return 1
  }

  : >"$SING_LOG"
  nohup /usr/local/bin/sing-box run -c "$SING_CONFIG" >"$SING_LOG" 2>&1 8>&- 9>&- &
  echo $! >"$SING_PID"
  for _ in $(seq 1 40); do
    ip link show "$TUN_NAME" >/dev/null 2>&1 && break
    sleep 0.25
  done
  sing_running
  ip link show "$TUN_NAME" >/dev/null
  for _ in $(seq 1 10); do
    out=$(curl -4fsS --resolve "api.ipify.org:443:$API_IPIFY_A" \
      --connect-timeout 10 --max-time 25 https://api.ipify.org 2>/dev/null || true)
    [ "$out" = "$EXPECTED_EXIT" ] && break
    sleep 1
  done
  [ "$out" = "$EXPECTED_EXIT" ] || {
    echo "ERROR: TUN returned ${out:-unavailable}, expected $EXPECTED_EXIT" >&2
    return 1
  }
  write_profile
  check_profile --full
  "$WATCHDOG" start 8>&- 9>&- >/dev/null
}

show_logs() {
  echo '--- SSH tunnel log ---' >&2
  tail -60 "$SSH_LOG" 2>/dev/null >&2 || true
  echo '--- Xray log ---' >&2
  tail -80 "$XRAY_LOG" 2>/dev/null >&2 || true
  echo '--- sing-box log ---' >&2
  tail -100 "$SING_LOG" 2>/dev/null >&2 || true
}

handle_start_error() {
  local rc="$1"
  trap - ERR
  set +e
  echo "ERROR: 104-130-over-ssh activation failed; firewall remains fail-closed." >&2
  show_logs
  stop_runtime
  "$KILLSWITCH" >/dev/null 2>&1
  [ -e "$ENABLED" ] && "$WATCHDOG" start 8>&- 9>&- >/dev/null 2>&1
  exit "$rc"
}

show_status() {
  local ssh_state='stopped' xray_state='stopped' sing_state='stopped' tun='none'
  local firewall='normal' base='unavailable' current='unavailable' enabled='no'
  ssh_running && ssh_state='running' || true
  xray_running && xray_state='running' || true
  sing_running && sing_state='running' || true
  ip link show "$TUN_NAME" >/dev/null 2>&1 && tun="$TUN_NAME" || true
  [ "$(iptables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ] && firewall='fail-closed' || true
  [ -e "$ENABLED" ] && enabled='yes'
  xray_running && base=$(base_exit 2>/dev/null || printf unavailable)
  current=$(curl -4fsS --connect-timeout 3 --max-time 7 https://api.ipify.org 2>/dev/null || printf unavailable)
  printf 'profile=104-130-over-ssh\nenabled=%s\nssh=%s\nxray=%s\nsing_box=%s\ntun=%s\nfirewall=%s\nbase_exit=%s\ncurrent_exit=%s\n' \
    "$enabled" "$ssh_state" "$xray_state" "$sing_state" "$tun" "$firewall" "$base" "$current"
}

case "${1:-status}" in
  start)
    acquire_locks
    trap 'handle_start_error $?' ERR
    "$KILLSWITCH"
    stop_other_profiles
    touch "$ENABLED"
    start_runtime
    trap - ERR
    ;;
  recover)
    acquire_locks
    [ -e "$ENABLED" ] || {
      echo 'DISABLED profile=104-130-over-ssh'
      exit 3
    }
    trap 'handle_start_error $?' ERR
    "$KILLSWITCH"
    start_runtime
    trap - ERR
    ;;
  check)
    shift
    check_profile "$@"
    ;;
  status)
    show_status
    ;;
  quiesce)
    acquire_locks
    rm -f "$ENABLED"
    "$WATCHDOG" stop >/dev/null 2>&1 || true
    stop_runtime
    ;;
  stop)
    acquire_locks
    rm -f "$ENABLED"
    "$WATCHDOG" stop >/dev/null 2>&1 || true
    stop_runtime
    clear_firewall
    echo 'STOPPED profile=104-130-over-ssh firewall=normal'
    ;;
  *)
    echo 'usage: vless104130-ssh {start|recover|check [--quick|--full] [--quiet]|status|quiesce|stop}' >&2
    exit 64
    ;;
esac
