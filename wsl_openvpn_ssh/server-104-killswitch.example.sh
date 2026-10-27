#!/bin/bash
# Server-side killswitch for entry-server (104)
# iptables-persistent: policy DROP on all chains
# Prevents VPN client traffic from leaking via server's public IP

set -euo pipefail

# IPv4: DROP all by default
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# === INPUT (входящие) ===
-A INPUT -i lo -j ACCEPT
-A INPUT -i wg130 -j ACCEPT                                          # WireGuard к 130
-A INPUT -s <wg-peer-ip>/32 -p udp --dport 51821 -j ACCEPT          # WG handshake
-A INPUT -p tcp --dport 22 -j ACCEPT                                 # SSH admin
-A INPUT -p tcp --dport 80 -j ACCEPT                                 # HTTP (LE challenge)
-A INPUT -p tcp --dport 443 -j ACCEPT                                # HTTPS (VLESS вход)
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# === OUTPUT (исходящие) ===
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o wg130 -j ACCEPT                                         # WireGuard к 130
-A OUTPUT -d <exit-server-ip>/32 -p tcp --dport <exit-ssh-port> -j ACCEPT  # SSH туннели к exit
-A OUTPUT -d <wg-peer-ip>/32 -p udp --dport 51821 -j ACCEPT         # WG handshake
-A OUTPUT -p udp --dport 53 -j ACCEPT                                # DNS
-A OUTPUT -p tcp --dport 80 -j ACCEPT                                # HTTP (apt, LE)
-A OUTPUT -p tcp --dport 443 -j ACCEPT                               # HTTPS (LE ACME, DoH)
-A OUTPUT -p udp --dport 123 -j ACCEPT                               # NTP
-A OUTPUT -p icmp -j ACCEPT                                          # ICMP

# === MARK rules for direct-exit profile ===
# Если есть профиль с прямым выходом через сам сервер (freedom + mark):
-A OUTPUT -m mark --mark 104 -j ACCEPT                               # помеченный трафик

COMMIT
RULES

# IPv6: полный DROP
ip6tables-restore <<'RULES'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
RULES

# Сохранить для автозагрузки
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

echo "Killswitch entry-server active: policy DROP, only specific paths allowed."
echo "Allowed OUT: lo, wg130, exit-ssh, DNS, HTTP, HTTPS, NTP, ICMP, mark-104"
echo "All other traffic: BLOCKED (no leak via public IP)"
