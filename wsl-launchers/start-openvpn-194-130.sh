#!/bin/bash
set -euo pipefail

if [ -n "${OPENVPN_SSH_POWERSHELL_EXE:-}" ]; then
  POWERSHELL_EXE=$OPENVPN_SSH_POWERSHELL_EXE
elif command -v powershell.exe >/dev/null 2>&1; then
  POWERSHELL_EXE=$(command -v powershell.exe)
elif [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
  # Some WSL shells deliberately omit Windows directories from PATH even
  # though binfmt interop and the mounted Windows filesystem are available.
  POWERSHELL_EXE=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
else
  echo 'ERROR: Windows PowerShell interop is unavailable.' >&2
  exit 1
fi

WINDOWS_PROFILE=$("$POWERSHELL_EXE" -NoProfile -NonInteractive -Command '$env:USERPROFILE' | tr -d '\r')
WINDOWS_LAUNCHER=${OPENVPN_SSH_WINDOWS_LAUNCHER:-"${WINDOWS_PROFILE}\\Desktop\\Run_VPN_Tunnel_new.ps1"}

exec "$POWERSHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$WINDOWS_LAUNCHER"
