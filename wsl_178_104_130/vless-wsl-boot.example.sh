#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROFILE_FILE='/etc/vless-wsl/profile'
LOG='/var/log/vless130-boot.log'

mkdir -p /var/log
if [ -r "$PROFILE_FILE" ]; then
  PROFILE=$(tr -d '[:space:]' <"$PROFILE_FILE")
else
  PROFILE='104-130'
fi

# Firewall is applied synchronously before WSL starts cron or other background
# jobs. An invalid selector falls back to a closed 104 ruleset without starting
# an unknown VPN profile.
case "$PROFILE" in
  104-130)
    /usr/local/bin/killswitch-vless-104
    ;;
  178-104-130)
    /usr/local/bin/killswitch-vless-178
    ;;
  *)
    /usr/local/bin/killswitch-vless-104
    printf '[%s] ERROR: invalid boot profile %s; firewall left fail-closed\n' \
      "$(date -Is)" "$PROFILE" >>"$LOG"
    exit 64
    ;;
esac

# A WSL shutdown can interrupt an at job and leave it marked as running. Remove
# only jobs owned by this VPN switcher before the synchronous cold-boot start.
while read -r job _; do
  [ -n "$job" ] || continue
  if at -c "$job" 2>/dev/null | grep -Eq '/usr/local/bin/(switch-vless178-130-supervised|recover-vless178130|rollback-vless130-from-178)'; then
    atrm "$job" || true
  fi
done < <(atq 2>/dev/null || true)

case "$PROFILE" in
  104-130)
    /usr/local/bin/start-vless130
    ;;
  178-104-130)
    if ! /usr/local/bin/switch-vless178-130-supervised; then
      /usr/local/bin/rollback-vless130-from-178
    fi
    ;;
esac

service cron start >/dev/null 2>&1 || true
/work/settings/claude/ram_guard_v3_start.sh || true
