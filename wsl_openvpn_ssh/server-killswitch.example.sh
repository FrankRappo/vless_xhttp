#!/bin/sh
# Server-side killswitch: prevent VPN client traffic leaking via server's public IP
# if WireGuard (wg130) goes down. Traffic is DROPPED instead of exiting via eth0.

# Reset managed rules (idempotent)
iptables -D INPUT -i eth0 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i tun0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.8.0.10/32 -o eth0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.8.0.0/24 -o eth0 -j DROP 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.8.0.10/32 -o eth0 -j MASQUERADE 2>/dev/null || true

# Install rules
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I INPUT 1 -i eth0 -p tcp --dport 443 -j ACCEPT
iptables -I FORWARD 1 -s 10.8.0.10/32 -o eth0 -j ACCEPT
iptables -A FORWARD -s 10.8.0.0/24 -o eth0 -j DROP
iptables -t nat -A POSTROUTING -s 10.8.0.10/32 -o eth0 -j MASQUERADE
