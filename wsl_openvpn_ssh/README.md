# OpenVPN-over-SSH: WSL → Windows → SSH → 194 → 130

Апрельская версия, воспроизведённая и задокументированная 27.10.2026.

## Схема

```
WSL (OpenVPN клиент)
  → 172.x.x.1:8443 (portproxy на Windows)
    → 127.0.0.1:8443 (plink local forward)
      → SSH → exit-server:56777
        → OpenVPN server на :443
          → WireGuard → 130 → интернет
```

Exit IP: 130.x.x.x

## Компоненты

| Компонент | Где | Назначение |
|-----------|-----|------------|
| `start-tunnel.ps1` | Desktop | Запуск всей цепочки (portproxy + plink) |
| `stop-tunnel.ps1` | Desktop | Остановка + восстановление |
| `tunnel.conf` | /etc/openvpn/client/ | Конфиг OpenVPN клиента |
| `killswitch` | /usr/local/bin/ | Fail-closed firewall для WSL |
| `plink.exe` | PuTTY | SSH-транспорт (Windows) |
| `portproxy` | netsh | Проброс WSL→Windows (требует админа) |

## Запуск

### Шаг 1: Windows (от администратора)

```powershell
# Можно сохранить как start-tunnel.ps1 и запускать двойным кликом
$wslIp = (wsl.exe -d Ubuntu-24.04 -e sh -c "ip route show | grep default | awk '{print `$3}'").Trim()
if (-not $wslIp) { Write-Host "WSL не отвечает!"; exit }

# Portproxy: WSL gateway → Windows localhost
netsh interface portproxy reset
netsh interface portproxy add v4tov4 listenport=8443 listenaddress=$wslIp connectport=8443 connectaddress=127.0.0.1

# Обновить IP в конфиге WSL
$configPath = "\wsl.localhost\Ubuntu-24.04\etc\openvpn\client\tunnel.conf"
$content = Get-Content $configPath
$content = $content -replace "remote \d+\.\d+\.\d+\.\d+ 8443", "remote $wslIp 8443"
$content = $content -replace "route \d+\.\d+\.\d+\.\d+ 255\.255\.255\.255", "route $wslIp 255.255.255.255"
$content | Set-Content $configPath -Encoding Ascii

# Запустить plink SSH туннель
$plinkArgs = "-ssh -2 -P 56777 -N -l root -pw <password> -L 127.0.0.1:8443:127.0.0.1:443 <exit-server-ip>"
Start-Process "C:\Program Files\PuTTY\plink.exe" -ArgumentList $plinkArgs
```

### Шаг 2: WSL (в терминале)

```bash
# Включить killswitch
sudo /usr/local/bin/killswitch

# Запустить OpenVPN
sudo openvpn --config /etc/openvpn/client/tunnel.conf
```

### Шаг 3: Проверка

```bash
curl -4 ifconfig.me        # → 130.x.x.x
ip route get 1.1.1.1       # → via tun0
```

## Остановка

```bash
# В WSL — восстановить сеть
sudo iptables -F && sudo iptables -X
sudo iptables -P INPUT ACCEPT && sudo iptables -P FORWARD ACCEPT && sudo iptables -P OUTPUT ACCEPT

# Остановить OpenVPN (Ctrl+C или)
sudo pkill openvpn
```

```powershell
# В Windows (от админа) — убрать portproxy
netsh interface portproxy reset
```

## Killswitch (fail-closed)

Скрипт: `/usr/local/bin/killswitch`

```bash
#!/bin/bash
# Вся политика DROP — ничего не проходит без VPN
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i tun+ -j ACCEPT          # VPN туннель
iptables -A OUTPUT -o tun+ -j ACCEPT         # VPN туннель
iptables -A OUTPUT -d 172.16.0.0/12 -p tcp --dport 8443 -j ACCEPT  # SSH forward
iptables -A INPUT -s 172.16.0.0/12 -p tcp --sport 8443 -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
```

Поведение:
- Туннель упал → интернет в WSL полностью блокируется (защита от утечек)
- Никакой трафик не уходит мимо VPN
- Аварийное отключение — команды из раздела "Остановка"

## Конфиг OpenVPN (tunnel.conf)

```
client
proto tcp-client
remote <wsl-gateway-ip> 8443
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-128-GCM
tls-client
tls-version-min 1.2

route <wsl-gateway-ip> 255.255.255.255 net_gateway

# Секретные блоки (ca, cert, key, tls-crypt) хранить отдельно
```

## Требования

1. **Windows: права администратора** — для netsh portproxy
2. **WSL: запущен** — любая wsl-команда стартует его
3. **PuTTY (plink.exe)** — установлен
4. **OpenVPN** — установлен в WSL
5. **Порт 56777 на exit-сервере** — открыт для вашего IP

## Известные проблемы

- Порт 56777 на exit-сервере может быть закрыт фаерволом — нужно открывать для IP клиента
- IP клиента может быть динамическим — при смене нужно обновлять правило фаервола
- При блокировке порта см. альтернативу: SSH-jump через промежуточный сервер
