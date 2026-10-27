#!/bin/bash
set -euo pipefail

ENTRY_IP=${ENTRY_IP:-203.0.113.10}
ENTRY_SSH_PORT=${ENTRY_SSH_PORT:-22}

# The outer SSH connection is the only direct bootstrap transport. XHTTP,
# DNS, project tunnels, and all other WSL traffic must use the VPN TUN.
iptables -P OUTPUT DROP
ip6tables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

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

echo "Kill switch VLESS-over-SSH active: lo, tun+, and only ${ENTRY_IP}:${ENTRY_SSH_PORT}/tcp are allowed on eth0."
