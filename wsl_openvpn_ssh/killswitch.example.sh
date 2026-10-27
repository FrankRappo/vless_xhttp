#!/bin/bash
# Fail-closed killswitch для OpenVPN-over-SSH в WSL
# Политика: всё DROP, разрешены только VPN и SSH-forward

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i tun+ -j ACCEPT
iptables -A OUTPUT -o tun+ -j ACCEPT

# SSH forward к Windows gateway (port 8443)
iptables -A OUTPUT -d 172.16.0.0/12 -p tcp --dport 8443 -j ACCEPT
iptables -A INPUT -s 172.16.0.0/12 -p tcp --sport 8443 -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "Kill Switch активирован. Трафик разрешен только через VPN (tun+) и порт 8443."
