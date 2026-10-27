# OpenVPN-over-SSH launcher (апрельская версия)
# Запускать от администратора PowerShell

$wslIp = (wsl.exe -d Ubuntu-24.04 -e sh -c "ip route show | grep default | awk '{print `$3}'").Trim()
if (-not $wslIp) { Write-Host "WSL не отвечает!"; exit }

Write-Host "--- Настройка туннеля для IP: $wslIp ---" -ForegroundColor Cyan

# 1. Portproxy
netsh interface portproxy reset
netsh interface portproxy add v4tov4 listenport=8443 listenaddress=$wslIp connectport=8443 connectaddress=127.0.0.1
Write-Host "[+] Windows Portproxy обновлен." -ForegroundColor Green

# 2. Обновить конфиг в WSL
$configPath = "\\wsl.localhost\Ubuntu-24.04\etc\openvpn\client\tunnel.conf"
if (Test-Path $configPath) {
    $content = Get-Content $configPath
    $content = $content -replace "remote \d+\.\d+\.\d+\.\d+ 8443", "remote $wslIp 8443"
    $content = $content -replace "route \d+\.\d+\.\d+\.\d+ 255\.255\.255\.255", "route $wslIp 255.255.255.255"
    $content | Set-Content $configPath -Encoding Ascii
    Write-Host "[+] Конфиг в WSL обновлен." -ForegroundColor Green
}

# 3. Запустить plink
$plinkArgs = "-ssh -2 -P 56777 -N -l root -pw <password> -L 127.0.0.1:8443:127.0.0.1:443 <exit-server-ip>"
Start-Process "C:\Program Files\PuTTY\plink.exe" -ArgumentList $plinkArgs

Write-Host "`n--- ГОТОВО! ---" -ForegroundColor White
Write-Host "Теперь запусти OpenVPN в WSL:" -ForegroundColor Gray
Write-Host "sudo /usr/local/bin/killswitch" -ForegroundColor Yellow
Write-Host "sudo openvpn --config /etc/openvpn/client/tunnel.conf" -ForegroundColor White
