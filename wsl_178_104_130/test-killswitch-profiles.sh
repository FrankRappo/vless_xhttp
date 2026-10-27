#!/bin/bash
set -euo pipefail

KILLSWITCH_104=${KILLSWITCH_104:-/usr/local/bin/killswitch-vless-104}
KILLSWITCH_178=${KILLSWITCH_178:-/usr/local/bin/killswitch-vless-178}
KILLSWITCH_104_SSH=${KILLSWITCH_104_SSH:-/usr/local/bin/killswitch-vless-104-ssh}

run_case() {
  local name="$1" script="$2" target="$3" port="$4" established="$5"
  echo "Testing $name in an isolated network namespace..."
  local hosts_file
  hosts_file=$(mktemp)
  cp /etc/hosts "$hosts_file"
  trap 'rm -f "$hosts_file"' RETURN
  unshare --net env KILLSWITCH="$script" TARGET="$target" PORT="$port" ESTABLISHED="$established" HOSTS_FILE="$hosts_file" bash -ceu '
    bash "$KILLSWITCH" >/dev/null
    [ "$(iptables -S INPUT | head -n 1)" = "-P INPUT DROP" ]
    [ "$(iptables -S FORWARD | head -n 1)" = "-P FORWARD DROP" ]
    [ "$(iptables -S OUTPUT | head -n 1)" = "-P OUTPUT DROP" ]
    [ "$(ip6tables -S INPUT | head -n 1)" = "-P INPUT DROP" ]
    [ "$(ip6tables -S FORWARD | head -n 1)" = "-P FORWARD DROP" ]
    [ "$(ip6tables -S OUTPUT | head -n 1)" = "-P OUTPUT DROP" ]
    iptables -C OUTPUT -o lo -j ACCEPT
    iptables -C OUTPUT -o tun+ -j ACCEPT
    iptables -C OUTPUT -o eth0 -d "$TARGET" -p tcp --dport "$PORT" -j ACCEPT
    iptables -C INPUT -i eth0 -s "$TARGET" -p tcp --sport "$PORT" -j ACCEPT
    if [ "$ESTABLISHED" = yes ]; then
      iptables -C OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    else
      ! iptables -C OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1
      ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1
    fi
    if iptables -C OUTPUT -o eth0 -d 1.1.1.1 -j ACCEPT >/dev/null 2>&1; then
      echo "unexpected direct allow" >&2
      exit 1
    fi
    eth0_accept_count=$(iptables -S OUTPUT | grep -c -- "-o eth0.*-j ACCEPT" || true)
    [ "$eth0_accept_count" -eq 1 ]
  '
  echo "RULESET_OK profile=$name target=$target:$port ipv4=drop ipv6=drop"
}

run_case '104-130' "$KILLSWITCH_104" '203.0.113.10' '443' 'yes'
run_case '178-104-130' "$KILLSWITCH_178" '203.0.113.20' '443' 'yes'
run_case '104-130-over-ssh' "$KILLSWITCH_104_SSH" '203.0.113.10' '22' 'no'
echo 'ALL_KILLSWITCH_RULESETS_OK'
