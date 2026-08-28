# WSL VPN profile switching: 104→130 and 178→104→130

Дата: 2026-08-28

## Профили

| Имя | TUN | SOCKS | Разрешённый транспорт `eth0` | Exit |
|---|---|---:|---|---|
| `104-130` | `tun-vless130` | `127.0.0.1:10808` | `203.0.113.10:443` | `198.51.100.130` |
| `178-104-130` | `tun-vless178130` | `127.0.0.1:10810` | `203.0.113.20:443` | `198.51.100.130` |

Оба набора конфигов хранятся постоянно, но одновременно запускается только
один TUN. Выбранный профиль записан в `/etc/vless-wsl/profile`.

## Команды

```bash
sudo /usr/local/bin/vless-wsl status
sudo /usr/local/bin/vless-wsl check
sudo /usr/local/bin/vless-wsl use 104-130
sudo /usr/local/bin/vless-wsl use 178-104-130
```

Команда `use 178-104-130` использует независимую `atd` job. До остановки
старого TUN выполняется preflight нового Xray через SOCKS `10810`. Выбор
профиля фиксируется только после проверки exit IP, DNS/HTTPS и killswitch.

Команда `use 104-130` выполняет независимый rollback, останавливает процессы и
watchdog профиля 178, удаляет его policy route и запускает сохранённый профиль
104.

## Killswitch

Обе схемы используют fail-closed правила:

- policy `DROP` для IPv4 INPUT/FORWARD/OUTPUT;
- policy `DROP` для IPv6 INPUT/FORWARD/OUTPUT;
- разрешены `lo` и `tun+`;
- через `eth0` разрешён только точный TCP transport активного entry на `443`;
- `ESTABLISHED,RELATED` сохранён согласно существующей operational-семантике.

Полный набор правил каждой IP-семьи загружается транзакцией через
`iptables-restore`/`ip6tables-restore`, а политики OUTPUT обеих семей
переводятся в `DROP` ещё первой командой boot. Это исключает окно с разрешённым
исходящим трафиком во время последовательного построения ruleset.

Проверки:

```bash
# Без изменения текущего firewall
sudo /usr/local/bin/vless-wsl test-rules

# Живой тест: остановить TUN, доказать блокировку и восстановить профиль
sudo /usr/local/bin/vless-wsl test-fail-closed
```

Успешный живой тест печатает:

```text
FAIL_CLOSED_OK profile=<имя> default=blocked eth0=blocked ipv6=blocked
HEALTHY profile=<имя> exit=198.51.100.130 fail_closed=yes
```

## Boot и health recovery

`/etc/wsl.conf` немедленно переводит IPv4/IPv6 OUTPUT в `DROP`, затем синхронно
вызывает `/usr/local/sbin/vless-wsl-boot`. Boot helper применяет полный
killswitch выбранного профиля, синхронно запускает и проверяет VPN и только
после этого запускает cron и RAM guard. Поэтому до готовности TUN исходящий
трафик остаётся закрыт, а WSL-сеанс не завершается посреди фоновой `atd` job.

Холодный старт после `wsl --shutdown` проверен для обоих selector: в самой
первой пользовательской команде IPv4 и IPv6 OUTPUT уже имели policy `DROP`,
прямой `curl --interface eth0` был заблокирован, затем выбранный профиль
восстановился с exit `198.51.100.130`; очереди `atd` и зависших lock не осталось.

`/usr/local/sbin/start-vless130-at-boot` оставлен по старому пути для
совместимости, но теперь читает профильный selector. Его вызывает boot helper,
а `/etc/cron.d/vless130-health` повторяет ту же профильную health-проверку.

Общий `/run/vless-profile.lock` исключает гонку boot/cron, ручного switch и
recovery. Lock не наследуется долгоживущими Xray/sing-box/watchdog.

Ручная команда `vless-wsl use ...` не возвращает управление сразу после
постановки job, а ждёт проверенного конечного состояния. Это удерживает WSL
активным даже при запуске одной командой через `wsl.exe`.

## SSH и SSH-туннели к Aeza

SSH, SCP, SFTP и туннели `ssh -L`, `ssh -R`, `ssh -D` из WSL идут через
активный TUN. Для entry `203.0.113.20` напрямую через `eth0` исключён только
внешний транспорт Xray TCP/443; SSH TCP/22 остаётся в VPN-таблице 2022.
Широкого host route к 178 в main table нет, поскольку он обошёл бы это
разделение портов.

```bash
ssh root@203.0.113.20
ssh -L 127.0.0.1:18080:127.0.0.1:8080 root@203.0.113.20
ssh -D 127.0.0.1:1081 root@203.0.113.20
```

Не использовать `ssh -b <адрес-eth0>` или `BindAddress` на `eth0`: намеренный
прямой обход TUN будет заблокирован killswitch.

Проверка 2026-08-28 подтвердила маршруты: TCP/443 к 178 идёт через `eth0`, а
TCP/22 к 178 — через `tun-vless178130`; временный `ssh -L` через сервер 104
успешно открыл локальный listener и передал SSH banner.

Первый тест SSH к самой Aeza выявил дополнительное клиентское исключение в
`sing-box`: весь адрес 178 отправлялся в outbound `direct`, поэтому SSH обходил
Xray. Это правило удалено — для служебного TCP/443 достаточно точного `ip rule`
priority 8999 и `sockopt.interface=eth0` самого Xray. После перезапуска TUN
фактический вход `ssh root@203.0.113.20` успешен; `SSH_CONNECTION` на Aeza
показывает source `198.51.100.130`, а не реальный адрес Windows/WSL.

Если selector повреждён, wrapper не запускает неизвестный профиль, применяет
killswitch 104 и оставляет сеть fail-closed.


> Public export: production backups and credentials are intentionally excluded.
