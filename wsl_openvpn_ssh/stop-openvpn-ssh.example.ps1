#requires -RunAsAdministrator
param(
    [string]$Distro = 'Ubuntu-24.04',
    [int]$ForwardPort = 8443,
    [string]$WatchdogPath = "$PSScriptRoot\openvpn-ssh-watchdog.example.ps1"
)

$ErrorActionPreference = 'Stop'

$WatchdogPattern = [regex]::Escape([System.IO.Path]::GetFileName($WatchdogPath))
Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -match '^(powershell|pwsh)\.exe$' -and
        $_.CommandLine -match $WatchdogPattern
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

$ForwardPattern = [regex]::Escape(('127.0.0.1:{0}:127.0.0.1:443' -f $ForwardPort))
Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq 'ssh.exe' -and
        $_.CommandLine -match $ForwardPattern
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

wsl.exe -d $Distro -u root -- /usr/local/bin/openvpn-wsl stop
if ($LASTEXITCODE -ne 0) {
    throw "Cannot stop OpenVPN profile: $LASTEXITCODE"
}

$DefaultRoute = wsl.exe -d $Distro -u root -- ip route show default
$WslGateway = (($DefaultRoute | Select-Object -First 1) -split '\s+')[2]
if ($WslGateway -match '^\d{1,3}(\.\d{1,3}){3}$') {
    netsh interface portproxy delete v4tov4 listenaddress=$WslGateway listenport=$ForwardPort 2>$null | Out-Null
}

Write-Host 'OpenVPN over SSH and watchdog stopped; WSL firewall returned to normal.' -ForegroundColor Green
