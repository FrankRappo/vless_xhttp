#!/bin/bash
# Killswitch for profiles 217-104-194 and 217-104-149 (Relay 217)
# Fail-closed: DROP all, allow only relay:443 and tun+
set -euo pipefail

ENTRY_IP=${ENTRY_IP:-<relay-ip>}
ENTRY_PORT=${ENTRY_PORT:-443}

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
-A INPUT -i eth0 -s ${ENTRY_IP}/32 -p tcp --sport ${ENTRY_PORT} -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -o eth0 -d ${ENTRY_IP}/32 -p tcp --dport ${ENTRY_PORT} -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
RULES

ip6tables-restore <<'RULES'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
RULES

echo "Kill switch VLESS-217 active: lo, tun+, and only ${ENTRY_IP}:${ENTRY_PORT}/tcp on eth0."
