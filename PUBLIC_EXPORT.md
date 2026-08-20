# Public export policy

This repository is generated from a private operational workspace. It contains
architecture notes and configuration examples only.

The public export replaces:

- production IPv4 addresses and domains with RFC 5737/example values;
- every VLESS UUID with a deterministic, non-production example UUID;
- Reality private/public keys and short IDs with public example material;
- server passwords, access tokens, SSH keys, and local secret paths;
- client source IPs found in historical logs.

Backup directories and pre-change snapshots are excluded. The values in this
repository must not be deployed unchanged.
