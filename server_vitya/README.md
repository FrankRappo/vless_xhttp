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

## Network path from Russia

Route goes through TSPU/DPI equipment (hop 7, no ICMP response).
TSPU throttles but does not fully block when traffic looks like normal
web browsing to a Russian site (XHTTP + Russian SNI + packet-up).

Latency: ~49ms one way. Measured throughput: 99 Mbps from iOS device.
