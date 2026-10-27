# Standalone exit server — direct access from Russia (TSPU bypass)

## Breakthrough: four conditions for direct foreign-IP entry from Russia

Tested 2026-10-27 from Russian ISP (no VPN, no relay):

| # | Requirement | Why |
|---|-------------|-----|
| 1 | **XHTTP transport** (not TCP) | TCP+Reality is fingerprinted and blocked instantly |
| 2 | **Russian-whitelisted SNI** (e.g. ozon.ru) | Foreign SNIs (yahoo, icloud) get flagged after ~5 min |
| 3 | **Packet-up mode** (not stream-one) | Stream-one maintains one continuous stream — killed in ~20s |
| 4 | **Server-side DNS forwarding** | Without it, TUN clients (sing-box, iOS apps) cannot resolve domains |

All four are **necessary**. Missing any one causes failure:

| Config | Result |
|--------|--------|
| TCP + Reality + Vision (any SNI) | blocked immediately |
| XHTTP + foreign SNI | works ~5 minutes, then DPI catches it |
| XHTTP + ozon SNI + stream-one | works ~20 seconds, then dies |
| XHTTP + ozon SNI + packet-up (no DNS) | TUN clients get blank pages |
| **XHTTP + ozon SNI + packet-up + DNS** | **works, 99 Mbps sustained** |

## DNS configuration (critical fix)

Add to xray server config:

```json
"dns": {
    "servers": [
        {"address": "1.1.1.1"},
        {"address": "8.8.8.8"}
    ],
    "queryStrategy": "UseIPv4"
}
```

Freedom outbound must have:
```json
{"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}}
```

Note: DNS fix takes effect after 1-2 minutes (client DNS cache must expire).

## Architecture

- VLESS + Reality + XHTTP packet-up on port 2053
- Reality target: Russian whitelisted site (TLS 1.3 + H2 required)
- Freedom outbound with DNS forwarding
- One UUID per user for log distinguishability


## Discovery: Path warming — bypassing initial DPI block

When a VPN connection to the server fails to establish, sending a few ICMP
ping packets from ANY device on the same network (same public IP) immediately
allows the connection to succeed.

### Mechanism

The TSPU/DPI is a **stateful firewall**. It maintains session tables mapping
source IP → destination IP. When any traffic (including benign ICMP) traverses
the TSPU from the client's IP to the server, the DPI creates/refreshes a
session entry. Subsequent connections (including VPN) from the same source IP
are then allowed through — the path is "warmed".

```
Laptop ──ICMP──→ DPI/TSPU ──→ Server    (session created)
iPhone ──VPN────→ DPI/TSPU ──→ Server    (allowed: session exists)
```

### Requirements

- Ping must originate from a device **behind the same NAT** (same public IP)
- Ping must be sent **before or during** VPN connection attempt
- 5-10 pings (2-3 seconds) is sufficient
- Pings from the SERVER do NOT help (return path bypasses TSPU)


### Three levels of TSPU blocking — when path warming works

| Level | Behavior | Path warming | Status |
|-------|----------|:------------:|:------:|
| **1. DPI analysis** | TCP passes, filter checks traffic patterns | ✅ works | current |
| **2. Throttling** | Connection passes, speed reduced | ⚠️ partial | — |
| **3. Full IP block** | TCP SYN dropped, ping fails | ❌ useless | — |

**Quick check:** `ping -c 10 <server-ip>`
- 10/10 replies at normal latency → level 1, path warming works
- Replies but slow (>200ms) → level 2
- 0/10 → level 3, IP fully blocked, need new IP or relay


This technique is known as **"path warming"** or **"session priming"** in the
anti-censorship community.


## Network path from Russia

Route goes through TSPU/DPI equipment (hop 7, no ICMP response).
TSPU throttles but does not fully block when traffic looks like normal
web browsing to a Russian site (XHTTP + Russian SNI + packet-up).

Latency: ~49ms one way. Measured throughput: 99 Mbps from iOS device.
