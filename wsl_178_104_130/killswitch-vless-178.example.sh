#!/bin/bash
set -e

# Intentionally preserves the operational semantics of killswitch-vless-104:
# manual activation and generic ESTABLISHED,RELATED remain by owner decision.
# Fail closed before replacing the complete ruleset.  iptables-restore applies
# each family as one transaction, so concurrent traffic never sees a partially
# constructed IPv4/IPv6 ruleset.
iptables -P OUTPUT DROP
ip6tables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

iptables-restore <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -i tun+ -j ACCEPT
-A INPUT -i eth0 -s 203.0.113.20/32 -p tcp --sport 443 -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -o eth0 -d 203.0.113.20/32 -p tcp --dport 443 -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
COMMIT
EOF

ip6tables-restore <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
EOF
echo "Kill Switch VLESS 178 активирован: разрешены lo, tun+, и eth0 только к 203.0.113.20:443; ESTABLISHED,RELATED сохранён намеренно."
