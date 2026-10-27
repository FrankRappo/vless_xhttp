# Standalone exit server (example: Vitya)

Direct VLESS exit with Reality — no chaining, freedom outbound only.

## Architecture (sanitized)

| Port | Transport | Target (SNI) | Flow |
|------|-----------|--------------|------|
| 443 | TCP + Reality + Vision | www.yahoo.com | `xtls-rprx-vision` |
| 8443 | TCP + Reality + Vision | www.icloud.com | `xtls-rprx-vision` |
| 2053 | XHTTP (`/up`, mode auto) + Reality | www.icloud.com | — |

All three inbounds share the same Reality keypair and shortId.
Outbound: `freedom` (direct exit) + `blackhole` (block).

## Example config structure

See `xray-config.example.json` for the full sanitized config.

## Notes

- Vision flow requires client fingerprint to be set (`fp=chrome` recommended)
- Reality target must support TLS 1.3 + H2
- Same UUID can be used across all inbounds (single-user per UUID pattern)
- To add a new user: append UUID to each inbound's `clients` list, restart xray
