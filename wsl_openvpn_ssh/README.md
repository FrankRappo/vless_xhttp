# OpenVPN-over-SSH для WSL — полный запуск, джамп и обход транзитных проблем

Схема:

    WSL (OpenVPN клиент)
      → 172.x.x.1:8443 (SSH forward на Windows)
        → plink → SSH jump через relay (порт 22)
          → exit-сервер (порт 56777)
            → OpenVPN → WireGuard → exit 130

Exit IP: 130.x.x.x (назначенный)

## Запуск (одна команда с Windows)

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\start-openvpn-ssh.ps1"
```

Требования: WSL запущен (любая команда `wsl -d <distro> -- echo ok` стартует его).
Права администратора Windows НЕ требуются.

Что делает лаунчер:
1. Определяет IP шлюза WSL
2. Поднимает SSH forward через plink → relay → exit (3 попытки по 30 сек)
3. Запускает в WSL `openvpn-wsl start` (OpenVPN + killswitch + watchdog)
4. Запускает Windows-watchdog (следит за SSH forward)

Успешный результат:
```
HEALTHY profile=openvpn-ssh-194-130 exit=130.x.x.x fail_closed=yes
OpenVPN over SSH is healthy; watchdog PID <pid>
```

## Остановка

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\stop-openvpn-ssh.ps1"
```

## SSH Jump конфигурация

Файл: `~/.ssh/config_jump` на Windows

```
Host exitjump
    HostName <exit-server-ip>
    Port 56777
    User root
    IdentityFile ~/.ssh/jump_key
    ProxyCommand "plink.exe" -ssh -batch -pw <relay-password> -nc %h:%p root@<relay-ip>
```

Компоненты:
- **plink** (PuTTY) — устанавливает SSH к relay-серверу
- **relay-сервер** — промежуточный узел (обход DPI на прямом SSH)
- **jump_key** — SSH-ключ для exit-сервера (не пароль)
- **-nc %h:%p** — прозрачный forward к exit-серверу

## ⚠️ Проблема транзитного провайдера (RETN)

Обнаружено: маршрут relay → exit может рваться на транзитном провайдере RETN.

Симптомы:
- Ping проходит (ICMP идёт по другому пути)
- TCP открывается (SYN доходит)
- SSH handshake висит (обратные пакеты теряются на RETN)

Диагностика:
```bash
# С relay-сервера:
traceroute -n <exit-ip>
# Если маршрут умирает после 87.245.x.x (RETN) — проблема подтверждена
```

Решение: сменить джамп-хост с relay на другой входной сервер,
у которого другой транзитный провайдер (например GTT).

## Killswitch (fail-closed)

После запуска профиля применяется killswitch:
- `iptables -P OUTPUT DROP` — всё закрыто по умолчанию
- Разрешены только: `lo`, `tun+` (VPN), SSH forward порт
- Если туннель умирает — интернет в WSL полностью блокируется (защита от утечек)

## Watchdog

- **WSL-side** (`openvpn-wsl-watchdog`): каждые 15 сек проверяет процессы + TUN + probe данных
- **Windows-side** (`OpenVPN_SSH_Watchdog.ps1`): следит за SSH forward, пересоздаёт при обрыве

## DNS на exit-сервере

Для работы TUN-клиентов на exit-сервере нужен DNS-форвардинг:

```json
"dns": {
    "servers": [
        {"address": "1.1.1.1"},
        {"address": "8.8.8.8"}
    ],
    "queryStrategy": "UseIPv4"
}
```

И freedom outbound с `domainStrategy: "UseIPv4"`.

## Аварийное отключение killswitch

```bash
sudo iptables -F && sudo iptables -X
sudo iptables -P INPUT ACCEPT && sudo iptables -P FORWARD ACCEPT && sudo iptables -P OUTPUT ACCEPT
```

## Известные проблемы

1. **Stream-one mode** умирает через ~20 сек — использовать packet-up
2. **Чужие SNI** (yahoo, icloud) блокируются ТСПУ через ~5 мин — использовать ру-белые
3. **RETN транзит** может рвать SSH между серверами — мониторить traceroute'ом
4. **Первое подключение** может не пройти — см. path warming (прогрев пути)
