#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROFILE_DIR='/etc/vless-wsl'
PROFILE_FILE="$PROFILE_DIR/profile"
PROFILE_LOCK='/run/vless-profile.lock'
EXPECTED_EXIT='198.51.100.130'
OLD_XRAY='/opt/vless_xhttp/wsl_130/xray-client1-104.json'
OLD_SING='/opt/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
NEW_XRAY='/opt/vless_xhttp/wsl_178_104_130/xray-wsl-178-104-130.json'
NEW_SING='/opt/vless_xhttp/wsl_178_104_130/sing-box-tun-178-104-130.json'

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

read_profile() {
  if [ -r "$PROFILE_FILE" ]; then
    tr -d '[:space:]' <"$PROFILE_FILE"
  else
    printf '%s' '104-130'
  fi
}

write_profile() {
  local profile="$1" tmp
  install -d -m 0755 "$PROFILE_DIR"
  tmp="${PROFILE_FILE}.$$"
  printf '%s\n' "$profile" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

acquire_profile_lock() {
  exec 8>"$PROFILE_LOCK"
  flock 8
  export VLESS_PROFILE_LOCK_HELD=1
}

process_running() {
  pgrep -f "^$1$" >/dev/null 2>&1
}

old_processes_running() {
  process_running "/usr/local/bin/xray run -c $OLD_XRAY" &&
    process_running "/usr/local/bin/sing-box run -c $OLD_SING" &&
    ip link show tun-vless130 >/dev/null 2>&1
}

new_processes_running() {
  process_running "/usr/local/bin/xray run -c $NEW_XRAY" &&
    process_running "/usr/local/bin/sing-box run -c $NEW_SING" &&
    ip link show tun-vless178130 >/dev/null 2>&1
}

exit_is_correct() {
  local out attempt
  for attempt in 1 2 3; do
    out=$(curl -4fsS --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null || true)
    [ "$out" = "$EXPECTED_EXIT" ] && return 0
    [ "$attempt" -lt 3 ] && sleep 1
  done
  echo "ERROR: expected exit $EXPECTED_EXIT, got ${out:-unavailable}" >&2
  return 1
}

assert_firewall() {
  local target="$1" unexpected
  [ "$(iptables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  [ "$(iptables -S INPUT | head -n 1)" = '-P INPUT DROP' ]
  [ "$(iptables -S FORWARD | head -n 1)" = '-P FORWARD DROP' ]
  [ "$(ip6tables -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
  [ "$(ip6tables -S INPUT | head -n 1)" = '-P INPUT DROP' ]
  [ "$(ip6tables -S FORWARD | head -n 1)" = '-P FORWARD DROP' ]
  iptables -C OUTPUT -o eth0 -d "$target" -p tcp --dport 443 -j ACCEPT
  iptables -C INPUT -i eth0 -s "$target" -p tcp --sport 443 -j ACCEPT
  unexpected=$(iptables -S OUTPUT | awk -v target="$target/32" '
    $1 == "-A" && $2 == "OUTPUT" && /-o eth0/ && /-j ACCEPT/ && index($0, "-d " target) == 0 { print }
  ')
  if [ -n "$unexpected" ]; then
    echo "ERROR: unexpected eth0 allow rule: $unexpected" >&2
    return 1
  fi
}

assert_no_leaks() {
  if curl -4fsS --interface eth0 --connect-timeout 3 --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: direct eth0 HTTPS leak detected' >&2
    return 1
  fi
  if curl -4fsS --interface eth0 --connect-timeout 3 --max-time 5 telnet://1.1.1.1:53 </dev/null >/dev/null 2>&1; then
    echo 'ERROR: direct eth0 TCP/53 leak detected' >&2
    return 1
  fi
  if curl -6fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: IPv6 leak detected' >&2
    return 1
  fi
}

check_profile() {
  local profile="$1"
  case "$profile" in
    104-130)
      old_processes_running
      ss -lntH | grep -q '127.0.0.1:10808'
      assert_firewall '203.0.113.10'
      ;;
    178-104-130)
      /usr/local/bin/check-vless178130 --full
      assert_firewall '203.0.113.20'
      ;;
    *)
      echo "ERROR: invalid selected profile: $profile" >&2
      return 64
      ;;
  esac
  exit_is_correct
  assert_no_leaks
  echo "HEALTHY profile=$profile exit=$EXPECTED_EXIT fail_closed=yes"
}

queue_once() {
  local target="$1" job
  service atd start 8>&- 9>&- >/dev/null
  if pgrep -f "^$target$" >/dev/null 2>&1; then
    echo "Already running: $target"
    return 0
  fi
  while read -r job _; do
    [ -n "$job" ] || continue
    if at -c "$job" 2>/dev/null | grep -Fq "$target"; then
      echo "Already queued as at job $job: $target"
      return 0
    fi
  done < <(atq)
  printf 'env -u VLESS_PROFILE_LOCK_HELD %s\n' "$target" | at -M now 8>&- 9>&-
}

wait_for_profile() {
  local wanted="$1" state
  for _ in $(seq 1 120); do
    if [ "$(read_profile)" = "$wanted" ]; then
      if [ "$wanted" = '104-130' ] && old_processes_running && exit_is_correct; then
        check_profile "$wanted"
        return 0
      fi
      if [ "$wanted" = '178-104-130' ] && /usr/local/bin/check-vless178130 --quick --quiet; then
        check_profile "$wanted"
        return 0
      fi
    fi
    if [ "$wanted" = '178-104-130' ] && [ -r /run/vless178130-switch.state ]; then
      state=$(cat /run/vless178130-switch.state)
      case "$state" in
        ROLLED_BACK*|ROLLBACK_FAILED*)
          echo "ERROR: switch did not complete: $state" >&2
          return 1
          ;;
      esac
    fi
    sleep 2
  done
  echo "ERROR: timed out waiting for profile $wanted" >&2
  show_status >&2
  return 1
}

show_status() {
  local profile old='stopped' new='stopped' tun='none' transport='unknown' out='unavailable'
  profile=$(read_profile)
  old_processes_running && old='running' || true
  new_processes_running && new='running' || true
  ip link show tun-vless130 >/dev/null 2>&1 && tun='tun-vless130'
  ip link show tun-vless178130 >/dev/null 2>&1 && tun='tun-vless178130'
  if iptables -C OUTPUT -o eth0 -d 203.0.113.10 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1; then
    transport='203.0.113.10:443'
  elif iptables -C OUTPUT -o eth0 -d 203.0.113.20 -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1; then
    transport='203.0.113.20:443'
  fi
  out=$(curl -4fsS --connect-timeout 4 --max-time 10 https://api.ipify.org 2>/dev/null || printf '%s' 'unavailable')
  printf 'selected=%s\nold_profile=%s\nnew_profile=%s\ntun=%s\nallowed_transport=%s\nexit=%s\n' \
    "$profile" "$old" "$new" "$tun" "$transport" "$out"
}

restore_after_fail_closed_test() {
  local profile="$1"
  case "$profile" in
    104-130) /usr/local/bin/start-vless130 ;;
    178-104-130) /usr/local/bin/recover-vless178130 ;;
  esac
}

test_fail_closed() {
  local profile="$1" sing_config restored=0 rc=0
  exec 8>"$PROFILE_LOCK"
  flock 8
  export VLESS_PROFILE_LOCK_HELD=1

  check_profile "$profile"
  if [ "$profile" = '178-104-130' ]; then
    sing_config="$NEW_SING"
    /usr/local/bin/vless178130-watchdog stop >/dev/null 2>&1 || true
  else
    sing_config="$OLD_SING"
  fi

  cleanup() {
    local original_rc=$?
    trap - EXIT INT TERM
    if [ "$restored" -eq 0 ]; then
      echo "Restoring profile $profile..."
      restore_after_fail_closed_test "$profile" || original_rc=1
    fi
    exit "$original_rc"
  }
  trap cleanup EXIT INT TERM

  pkill -f "/usr/local/bin/sing-box run -c ${sing_config}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -f "^/usr/local/bin/sing-box run -c ${sing_config}$" >/dev/null 2>&1 || break
    sleep 1
  done
  sleep 2

  if curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: default traffic escaped after TUN stop' >&2
    rc=1
  fi
  if curl -4fsS --interface eth0 --connect-timeout 3 --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: eth0 traffic escaped after TUN stop' >&2
    rc=1
  fi
  if curl -6fsS --connect-timeout 3 --max-time 6 https://api64.ipify.org >/dev/null 2>&1; then
    echo 'ERROR: IPv6 traffic escaped after TUN stop' >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "FAIL_CLOSED_OK profile=$profile default=blocked eth0=blocked ipv6=blocked"
  fi

  restore_after_fail_closed_test "$profile"
  restored=1
  check_profile "$profile"
  trap - EXIT INT TERM
  return "$rc"
}

usage() {
  cat <<'EOF'
usage:
  vless-wsl status
  vless-wsl check
  vless-wsl use 104-130
  vless-wsl use 178-104-130
  vless-wsl test-rules
  vless-wsl test-fail-closed
EOF
}

COMMAND=${1:-status}
case "$COMMAND" in
  status)
    show_status
    ;;
  check)
    check_profile "$(read_profile)"
    ;;
  use)
    PROFILE=${2:-}
    case "$PROFILE" in
      104-130)
        acquire_profile_lock
        if old_processes_running && ! new_processes_running && exit_is_correct; then
          /usr/local/bin/killswitch-vless-104
          write_profile '104-130'
          check_profile '104-130'
        else
          exec 8>&-
          unset VLESS_PROFILE_LOCK_HELD
          queue_once '/usr/local/bin/rollback-vless130-from-178'
          echo 'Switch to 104-130 queued; waiting for verified completion.'
          wait_for_profile '104-130'
        fi
        ;;
      178-104-130)
        /usr/local/bin/start-vless178130
        echo 'Switch to 178-104-130 requested; waiting for verified completion.'
        wait_for_profile '178-104-130'
        ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  test-rules)
    /opt/vless_xhttp/wsl_178_104_130/test-killswitch-profiles.sh
    ;;
  test-fail-closed)
    test_fail_closed "$(read_profile)"
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
