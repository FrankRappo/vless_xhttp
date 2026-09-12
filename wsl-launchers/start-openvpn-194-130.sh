#!/bin/bash
set -euo pipefail

if ! command -v powershell.exe >/dev/null 2>&1; then
  echo 'ERROR: Windows PowerShell interop is unavailable.' >&2
  exit 1
fi

WINDOWS_PROFILE=$(powershell.exe -NoProfile -NonInteractive -Command '$env:USERPROFILE' | tr -d '\r')
WINDOWS_LAUNCHER=${OPENVPN_SSH_WINDOWS_LAUNCHER:-"${WINDOWS_PROFILE}\\Desktop\\Run_VPN_Tunnel_new.ps1"}

exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_LAUNCHER"
