#!/bin/bash
set -e

PIN_HOST="203.0.113.10 entry.example.com # vless-wsl-130 pin"
if ! grep -qE '(^|[[:space:]])news\.cjd\.wales([[:space:]]|$)' /etc/hosts; then
  echo "$PIN_HOST" >> /etc/hosts
elif ! grep -qF '203.0.113.10 entry.example.com' /etc/hosts; then
  sed -i '/news\.cjd\.wales/d' /etc/hosts
  echo "$PIN_HOST" >> /etc/hosts
fi

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
-A INPUT -i eth0 -s 203.0.113.10/32 -p tcp --sport 443 -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -o eth0 -d 203.0.113.10/32 -p tcp --dport 443 -j ACCEPT
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
echo "Kill Switch VLESS активирован: hosts pin entry.example.com=203.0.113.10, разрешены lo, tun+, и eth0 только к 203.0.113.10:443."
