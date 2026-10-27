#!/bin/bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# WSL starts with normal networking. VPN-specific fail-closed rules are applied
# only by the corresponding explicit VPN start command.
service cron start >/dev/null 2>&1 || true
/work/settings/claude/ram_guard_v3_start.sh >/dev/null 2>&1 || true
