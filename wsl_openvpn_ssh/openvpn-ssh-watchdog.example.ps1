#requires -RunAsAdministrator
param(
    [string]$Distro = 'Ubuntu-24.04',
    [string]$KeyPath = "$HOME\.ssh\jump194",
    [string]$RemoteHost = '192.0.2.194',
    [int]$RemotePort = 56777,
    [int]$ForwardPort = 8443,
    [int]$AdoptSshPid = 0,
    [int]$HealthIntervalSeconds = 15,
    [int]$RetrySeconds = 3,
    [int]$FailureThreshold = 2
)

$ErrorActionPreference = 'Continue'
$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$WslExe = "$env:WINDIR\System32\wsl.exe"
$LogDirectory = Join-Path $env:LOCALAPPDATA 'OpenVPN-SSH'
$LogPath = Join-Path $LogDirectory 'watchdog.log'
$MutexName = 'Global\OpenVPN-SSH-Watchdog-' + ($Distro -replace '[^A-Za-z0-9_.-]', '_') + "-$ForwardPort"

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

function Write-Log {
    param([string]$Message)

    if ((Test-Path -LiteralPath $LogPath) -and
        (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
    }
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
        '{0:o} {1}' -f (Get-Date), $Message
    )
}

function Test-DistroRunning {
    $Names = & $WslExe --list --running --quiet 2>$null
    foreach ($Name in @($Names)) {
        $CleanName = (([string]$Name) -replace [char]0, '').Trim()
        if ($CleanName -eq $Distro) {
            return $true
        }
    }
    return $false
}

function Test-ProfileEnabled {
    & $WslExe -d $Distro -u root -- test -e /run/openvpn-wsl.enabled 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-ProfileHealthy {
    & $WslExe -d $Distro -u root -- /usr/local/bin/openvpn-wsl check *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ProfileRecovery {
    $Output = & $WslExe -d $Distro -u root -- /usr/local/bin/openvpn-wsl recover 2>&1
    $Code = $LASTEXITCODE
    if ($Code -eq 0) {
        Write-Log 'OpenVPN is healthy.'
    } elseif ($Code -eq 3) {
        Write-Log 'Manual profile state is disabled; watchdog is stopping.'
    } else {
        Write-Log ("OpenVPN recovery failed with code {0}: {1}" -f $Code, ($Output -join ' '))
    }
    return $Code
}

function Start-SshForward {
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
    Write-Log "Starting SSH forward through $RemoteHost`:$RemotePort."
    return Start-Process -FilePath $SshExe -ArgumentList $SshArgs -WindowStyle Hidden -PassThru
}

function Wait-SshForward {
    param([System.Diagnostics.Process]$Process)

    for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
        Start-Sleep -Milliseconds 500
        if ($Process.HasExited) {
            return $false
        }
        $Listener = Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 `
            -LocalPort $ForwardPort -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -eq $Process.Id
        if ($Listener) {
            return $true
        }
    }
    return $false
}

$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$HasMutex = $false
$SshProcess = $null

try {
    try {
        $HasMutex = $Mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $HasMutex = $true
    }

    if (-not $HasMutex) {
        exit 0
    }

    if ($AdoptSshPid -gt 0) {
        $SshProcess = Get-Process -Id $AdoptSshPid -ErrorAction SilentlyContinue
    }

    Write-Log 'Watchdog started.'

    :Supervisor while (Test-DistroRunning) {
        if (-not (Test-ProfileEnabled)) {
            break
        }

        if (($null -eq $SshProcess) -or $SshProcess.HasExited) {
            $SshProcess = Start-SshForward
        }

        if (-not (Wait-SshForward -Process $SshProcess)) {
            Write-Log 'SSH forward did not become ready.'
            if (-not $SshProcess.HasExited) {
                Stop-Process -Id $SshProcess.Id -Force -ErrorAction SilentlyContinue
            }
            $SshProcess = $null
            Start-Sleep -Seconds $RetrySeconds
            continue
        }

        $RecoveryCode = Invoke-ProfileRecovery
        if ($RecoveryCode -eq 3) {
            break
        }

        $ConsecutiveFailures = 0
        while (-not $SshProcess.HasExited) {
            if ($SshProcess.WaitForExit($HealthIntervalSeconds * 1000)) {
                break
            }

            if (-not (Test-DistroRunning)) {
                break Supervisor
            }
            if (-not (Test-ProfileEnabled)) {
                break Supervisor
            }
            if (Test-ProfileHealthy) {
                $ConsecutiveFailures = 0
                continue
            }
            if ($SshProcess.HasExited) {
                break
            }

            $ConsecutiveFailures++
            Write-Log ("Health check failed ({0}/{1})." -f $ConsecutiveFailures, $FailureThreshold)
            if ($ConsecutiveFailures -lt $FailureThreshold) {
                continue
            }

            Write-Log 'Consecutive health checks failed; recovering without clearing firewall.'
            $RecoveryCode = Invoke-ProfileRecovery
            $ConsecutiveFailures = 0
            if ($RecoveryCode -eq 3) {
                break Supervisor
            }
        }

        Write-Log 'SSH forward exited; retrying while kill switch remains active.'
        $SshProcess = $null
        Start-Sleep -Seconds $RetrySeconds
    }
} catch {
    Write-Log ("Watchdog error: {0}" -f $_.Exception.Message)
} finally {
    if (($null -ne $SshProcess) -and (-not $SshProcess.HasExited)) {
        Stop-Process -Id $SshProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Watchdog stopped.'
    if ($HasMutex) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}
