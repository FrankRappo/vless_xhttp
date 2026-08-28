#!/bin/bash
set -euo pipefail

run_case() {
  local name="$1" script="$2" target="$3"
  echo "Testing $name in an isolated network namespace..."
  unshare --net env KILLSWITCH="$script" TARGET="$target" bash -ceu '
    "$KILLSWITCH" >/dev/null
    [ "$(iptables -S INPUT | head -n 1)" = "-P INPUT DROP" ]
    [ "$(iptables -S FORWARD | head -n 1)" = "-P FORWARD DROP" ]
    [ "$(iptables -S OUTPUT | head -n 1)" = "-P OUTPUT DROP" ]
    [ "$(ip6tables -S INPUT | head -n 1)" = "-P INPUT DROP" ]
    [ "$(ip6tables -S FORWARD | head -n 1)" = "-P FORWARD DROP" ]
    [ "$(ip6tables -S OUTPUT | head -n 1)" = "-P OUTPUT DROP" ]
    iptables -C OUTPUT -o lo -j ACCEPT
    iptables -C OUTPUT -o tun+ -j ACCEPT
    iptables -C OUTPUT -o eth0 -d "$TARGET" -p tcp --dport 443 -j ACCEPT
    iptables -C INPUT -i eth0 -s "$TARGET" -p tcp --sport 443 -j ACCEPT
    iptables -C OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if iptables -C OUTPUT -o eth0 -d 1.1.1.1 -j ACCEPT >/dev/null 2>&1; then
      echo "unexpected direct allow" >&2
      exit 1
    fi
    eth0_accept_count=$(iptables -S OUTPUT | grep -c -- "-o eth0.*-j ACCEPT" || true)
    [ "$eth0_accept_count" -eq 1 ]
  '
  echo "RULESET_OK profile=$name target=$target:443 ipv4=drop ipv6=drop"
}

run_case '104-130' '/usr/local/bin/killswitch-vless-104' '203.0.113.10'
run_case '178-104-130' '/usr/local/bin/killswitch-vless-178' '203.0.113.20'
echo 'ALL_KILLSWITCH_RULESETS_OK'
