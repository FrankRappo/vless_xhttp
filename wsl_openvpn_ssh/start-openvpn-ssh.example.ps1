#requires -RunAsAdministrator
param(
    [string]$Distro = 'Ubuntu-24.04',
    [string]$KeyPath = "$HOME\.ssh\jump194",
    [string]$RemoteHost = '192.0.2.194',
    [int]$RemotePort = 56777,
    [int]$ForwardPort = 8443,
    [string]$WatchdogPath = "$PSScriptRoot\openvpn-ssh-watchdog.example.ps1"
)

$ErrorActionPreference = 'Stop'
$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$PowerShellExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

$DefaultRoute = wsl.exe -d $Distro -u root -- ip route show default
$WslGateway = (($DefaultRoute | Select-Object -First 1) -split '\s+')[2]
if ($WslGateway -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "Cannot determine the WSL gateway: '$DefaultRoute'"
}
if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "SSH key not found: $KeyPath"
}
if (-not (Test-Path -LiteralPath $WatchdogPath)) {
    throw "Watchdog script not found: $WatchdogPath"
}

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

netsh interface portproxy delete v4tov4 listenaddress=$WslGateway listenport=$ForwardPort 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=$WslGateway listenport=$ForwardPort connectaddress=127.0.0.1 connectport=$ForwardPort | Out-Null

$OpenVpnConfig = '/etc/openvpn/client/194_130wsl-over-ssh.conf'
$RemoteDirective = "remote $WslGateway $ForwardPort"
wsl.exe -d $Distro -u root -- sed -i -E '/^(ignore-unknown-option block-outside-dns|setenv opt block-outside-dns)/d' $OpenVpnConfig
if ($LASTEXITCODE -ne 0) {
    throw "Cannot normalize WSL options in $OpenVpnConfig"
}
wsl.exe -d $Distro -u root -- sed -i -E "s/^remote .*/$RemoteDirective/" $OpenVpnConfig
if ($LASTEXITCODE -ne 0) {
    throw "Cannot update OpenVPN endpoint in $OpenVpnConfig"
}

$ForwardSpec = '127.0.0.1:{0}:127.0.0.1:443' -f $ForwardPort
$SshArgs = @(
    '-N', '-T',
    '-i', $KeyPath,
    '-p', $RemotePort,
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=20',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-L', $ForwardSpec,
    "root@$RemoteHost"
)
$SshProcess = Start-Process -FilePath $SshExe -ArgumentList $SshArgs -WindowStyle Hidden -PassThru

$ForwardReady = $false
for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
    Start-Sleep -Milliseconds 500
    if ($SshProcess.HasExited) {
        throw "SSH forward exited with code $($SshProcess.ExitCode)"
    }
    $Listener = Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $ForwardPort -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -eq $SshProcess.Id
    if ($Listener) {
        $ForwardReady = $true
        break
    }
}
if (-not $ForwardReady) {
    Stop-Process -Id $SshProcess.Id -Force -ErrorAction SilentlyContinue
    throw 'SSH forward did not open 127.0.0.1:8443'
}

$StartOutput = wsl.exe -d $Distro -u root -- /usr/local/bin/openvpn-wsl start 2>&1
$StartCode = $LASTEXITCODE
$StartOutput | ForEach-Object { Write-Host $_ }

$WatchdogCommandLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Distro "{1}" -KeyPath "{2}" -RemoteHost "{3}" -RemotePort {4} -ForwardPort {5} -AdoptSshPid {6}' -f $WatchdogPath, $Distro, $KeyPath, $RemoteHost, $RemotePort, $ForwardPort, $SshProcess.Id
$WatchdogProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $WatchdogCommandLine -WindowStyle Hidden -PassThru

if ($StartCode -ne 0) {
    throw "Initial OpenVPN start failed with code $StartCode; watchdog PID $($WatchdogProcess.Id) continues fail-closed recovery."
}

Write-Host ("OpenVPN over SSH is healthy; watchdog PID {0}" -f $WatchdogProcess.Id) -ForegroundColor Green
