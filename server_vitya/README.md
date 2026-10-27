# Standalone exit server — DPI findings and architecture notes

## Key finding: XHTTP + Russian-whitelisted SNI bypasses DPI from foreign IP

Tested 2026-10-27 from Russian ISP (no VPN), foreign datacenter IP:

| Transport | SNI | Result |
|-----------|-----|--------|
| TCP + Reality + Vision | foreign (yahoo/icloud) | blocked immediately |
| XHTTP + Reality | foreign (yahoo) | works briefly (~5 min), then DPI catches it |
| **XHTTP + Reality** | **Russian whitelist (ozon)** | **works reliably** |

**Conclusion:** for a foreign-IP entry point accessible from Russia, BOTH are required:
1. XHTTP transport (raw TCP is fingerprinted and blocked)
2. Russian-whitelisted SNI (foreign SNIs get flagged after a few connections)

## Architecture

- VLESS + Reality + XHTTP on port 2053
- Reality target: Russian whitelisted site (TLS 1.3 + H2 required)
- Freedom outbound (direct exit, no chaining)
- One UUID per user for log distinguishability

## Adding a new user

1. Generate UUID
2. Append to `clients` list in the XHTTP inbound
3. Restart xray
4. Issue link with the new UUID, same Reality public key and shortId
