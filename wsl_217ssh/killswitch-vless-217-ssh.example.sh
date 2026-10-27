#!/bin/bash
# Killswitch for Double SSH profiles (WSL -> SSH 217 -> SSH 104 -> exit)
# Fail-closed: DROP all, allow only relay:22 and tun+
set -euo pipefail

ENTRY_IP=${ENTRY_IP:-<relay-ip>}
ENTRY_SSH_PORT=${ENTRY_SSH_PORT:-22}

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -i tun+ -j ACCEPT
-A INPUT -i eth0 -s ${ENTRY_IP}/32 -p tcp --sport ${ENTRY_SSH_PORT} -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -o eth0 -d ${ENTRY_IP}/32 -p tcp --dport ${ENTRY_SSH_PORT} -j ACCEPT
COMMIT
RULES

ip6tables-restore <<'RULES'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
RULES

echo "Kill switch VLESS-over-SSH active: lo, tun+, and only ${ENTRY_IP}:${ENTRY_SSH_PORT}/tcp on eth0."
