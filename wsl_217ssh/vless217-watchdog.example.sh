#!/bin/bash
# Watchdog for 217 profiles: checks every 15s, restarts after 2 failures
# Checks: processes + TUN + firewall + data probe (exit IP)
set -uo pipefail

PID='/run/vless217-watchdog.pid'
LOG='/var/log/vless217-watchdog.log'
PROFILE_FILE='/etc/vless-wsl/profile'

read_profile() { tr -d '[:space:]' <"$PROFILE_FILE" 2>/dev/null || printf ''; }

structure_alive() {
  local prof cfg_x cfg_s tun
  prof=$(read_profile)
  case "$prof" in
    217-104-194) cfg_x='<path>/xray-wsl-217-104-194.json'; cfg_s='<path>/sing-box-tun-217-104-194.json'; tun='tun-vless217194' ;;
    217-104-149) cfg_x='<path>/xray-wsl-217-104-149.json'; cfg_s='<path>/sing-box-tun-217-104-149.json'; tun='tun-vless217149' ;;
    *) return 1 ;;
  esac
  pgrep -f "xray run -c $cfg_x" >/dev/null 2>&1 || return 1
  pgrep -f "sing-box run -c $cfg_s" >/dev/null 2>&1 || return 1
  ip link show "$tun" >/dev/null 2>&1 || return 1
  iptables -C OUTPUT -o eth0 -d <relay-ip> -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || return 1
}

data_alive() {
  local expected out
  case "$(read_profile)" in
    217-104-194) expected=<exit-194-ip> ;;
    217-104-149) expected=<exit-149-ip> ;;
    *) return 1 ;;
  esac
  out=$(curl -4fsS --connect-timeout 4 --max-time 9 https://api.ipify.org 2>/dev/null || printf '')
  [ "$out" = "$expected" ]
}

case "${1:-status}" in
  start)
    # ... start-stop-daemon pattern
    ;;
  stop)
    # ... stop
    ;;
  run)
    while sleep 15; do
      case "$(read_profile)" in 217-*) ;; *) exit 0 ;; esac
      if structure_alive && data_alive; then
        continue
      fi
      # ... restart profile
    done
    ;;
esac
