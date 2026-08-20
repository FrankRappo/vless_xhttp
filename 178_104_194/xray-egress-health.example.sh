#!/bin/bash
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOCK=/run/xray-egress-health.lock
STATE=/run/xray-egress-health.state
THRESHOLD=2
COOLDOWN=30
exec 9>"$LOCK"
flock -n 9 || exit 0

probe() {
  port="$1"
  expected="$2"
  out=$(curl -4fsS --socks5-hostname "127.0.0.1:$port"     --connect-timeout 2 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [ "$out" = "$expected" ]
}

read_count() {
  file="$1"
  value=0
  [ -r "$file" ] && read -r value <"$file"
  case "$value" in
    ''|*[!0-9]*) value=0 ;;
  esac
  printf '%s' "$value"
}

check_route() {
  name="$1"
  port="$2"
  expected="$3"
  unit="$4"
  fail_file="/run/xray-egress-health-$name.failures"
  restart_file="/run/xray-egress-health-$name.last-restart"

  if systemctl is-active --quiet "$unit" && probe "$port" "$expected"; then
    printf '0\n' >"$fail_file"
    printf '%s=ok' "$name"
    return 0
  fi

  failures=$(read_count "$fail_file")
  failures=$((failures + 1))
  printf '%s\n' "$failures" >"$fail_file"

  if ! systemctl is-active --quiet "$unit"; then
    reason=inactive
  elif [ "$failures" -lt "$THRESHOLD" ]; then
    printf '%s=degraded(%s/%s)' "$name" "$failures" "$THRESHOLD"
    return 1
  else
    reason=probe-failed
  fi

  now=$(date +%s)
  last=0
  [ -r "$restart_file" ] && read -r last <"$restart_file"
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    printf '%s=failed(cooldown)' "$name"
    return 1
  fi

  printf '%s\n' "$now" >"$restart_file"
  echo "$name: targeted restart ($reason)" >&2
  systemctl restart "$unit"
  for _ in $(seq 1 8); do
    ss -lntH | grep -q "127.0.0.1:$port" && break
    sleep 1
  done
  if probe "$port" "$expected"; then
    printf '0\n' >"$fail_file"
    printf '%s=restarted-ok' "$name"
    return 0
  fi

  printf '%s=restart-failed' "$name"
  return 1
}

rc=0
relay194=$(check_route relay194 11041 203.0.113.30 xray-egress-194.service) || rc=1
relay130=$(check_route relay130 11042 198.51.100.130 xray-egress-130.service) || rc=1
relay149=$(check_route relay149 11043 203.0.113.40 xray-egress-149.service) || rc=1
checked=$(date -Is)
printf '%s %s %s checked=%s\n' "$relay194" "$relay130" "$relay149" "$checked"
tmp="$STATE.$$"
printf '%s %s %s checked=%s\n' "$relay194" "$relay130" "$relay149" "$checked" >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$STATE"
exit "$rc"
