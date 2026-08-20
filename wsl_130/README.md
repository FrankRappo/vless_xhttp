# WSL VLESS/XHTTP → 104 → 130 manual flow

Дата: 2026-05-26
Статус: **активный постоянный WSL-профиль с 2026-08-19 после rollback эксперимента через 178**. Настроено и проверено вручную; systemd для WSL не используется.

## Топология

```text
WSL process traffic
  -> sing-box TUN `tun-vless130`
  -> local Xray SOCKS `127.0.0.1:10808`
  -> VLESS/Reality/XHTTP `vpn.example.com:443`
  -> /etc/hosts pin: `vpn.example.com = 203.0.113.10`
  -> 104 entry Xray, только user/email `client1`
  -> Xray outbound `out-130`, mark `0x82`
  -> public TCP `198.51.100.130:10443`
  -> Xray on 130 (VLESS UUID auth; source IP intentionally unrestricted)
  -> Internet, exit IP `198.51.100.130`
```

Другие VLESS-клиенты на 104 остаются на старой схеме через `tunnel-balancer`.

## Файлы WSL

```text
/usr/local/bin/killswitch-vless-104
/usr/local/bin/xray
/usr/local/bin/sing-box
/work/vpn/vless_xhttp/wsl_130/xray-client1-104.json
/work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
/usr/local/sbin/start-vless130-at-boot
/etc/cron.d/vless130-health
/work/vpn/vless_xhttp/wsl_130/start-vless130-at-boot.example.sh
/work/vpn/vless_xhttp/wsl_130/vless130-health.cron.example
```

`/etc/hosts` содержит pin:

```text
203.0.113.10 vpn.example.com # vless-wsl-130 pin
```

## Ручной запуск

В WSL:

```bash
sudo /usr/local/bin/killswitch-vless-104

nohup sudo /usr/local/bin/xray run \
  -c /work/vpn/vless_xhttp/wsl_130/xray-client1-104.json \
  > /tmp/xray-vless130.log 2>&1 & echo $! > /tmp/xray-vless130.pid

nohup sudo /usr/local/bin/sing-box run \
  -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json \
  > /tmp/sing-vless130.log 2>&1 & echo $! > /tmp/sing-vless130.pid
```

## Обязательный тест после каждого запуска

```bash
# 1. Проверить pin домена
getent hosts vpn.example.com
# ожидаемо: 203.0.113.10 vpn.example.com

# 2. Проверить внешний IP через VPN
curl -4 --max-time 15 -sS https://api.ipify.org ; echo
# ожидаемо: 198.51.100.130

# 3. Проверить, что прямой eth0 не выпускает наружу
curl --interface eth0 -4 --max-time 10 -sS https://api.ipify.org || echo DIRECT_ETH0_BLOCKED
# ожидаемо: DIRECT_ETH0_BLOCKED

# 4. Проверить, что IPv6 не выходит
curl -6 --max-time 10 -sS https://api64.ipify.org || echo IPV6_BLOCKED
# ожидаемо: IPV6_BLOCKED

# 5. Проверить, что eth0-bound DNS/HTTP не утекают
curl --interface eth0 --max-time 8 -sS telnet://1.1.1.1:53 </dev/null || echo ETH0_DNS_TCP_BLOCKED
curl --interface eth0 --max-time 8 -sS http://1.1.1.1/ || echo ETH0_HTTP_BLOCKED
# ожидаемо: оба BLOCKED
```

## Fail-closed тест

```bash
# Остановить только TUN-клиент, имитируя падение VPN-клиента
sudo kill $(cat /tmp/sing-vless130.pid)
sleep 2

curl -4 --max-time 10 -sS https://api.ipify.org || echo DEFAULT_BLOCKED_AFTER_SINGBOX_STOP
curl --interface eth0 -4 --max-time 10 -sS https://api.ipify.org || echo DIRECT_ETH0_STILL_BLOCKED

# Вернуть sing-box
nohup sudo /usr/local/bin/sing-box run \
  -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json \
  >> /tmp/sing-vless130.log 2>&1 & echo $! > /tmp/sing-vless130.pid

curl -4 --max-time 15 -sS https://api.ipify.org ; echo
# ожидаемо снова: 198.51.100.130
```

## Остановка / сброс

Отдельный rollback-скрипт не создавался по договорённости. Если что-то заклинило:

```powershell
wsl --shutdown
```

Это сбросит непостоянные WSL iptables/routes/processes.

## Что уже проверено 2026-05-26

- `curl -4 https://api.ipify.org` через обычный путь WSL показал `198.51.100.130`.
- `curl --interface eth0` наружу заблокирован.
- IPv6-запрос заблокирован.
- После остановки `sing-box` обычный curl не вышел наружу, прямой `eth0` тоже остался заблокирован.
- После рестарта `sing-box` egress снова `198.51.100.130`.

---

## Серверная часть 104 для config 1

На entry VPS `203.0.113.10` клиент `client1` выделен отдельным routing-правилом Xray:

```text
inbound: in-reality-xhttp
user/email: client1
outboundTag: out-130
```

То есть только config 1 идёт по отдельной цепочке:

```text
client1 -> 104 Xray -> outbound out-130 (mark 0x82)
        -> 130 Xray 198.51.100.130:10443 -> Internet
```

Остальные VLESS-клиенты на 104 не используют `out-130` напрямую. Они идут через обычный `tunnel-balancer`.

Проверка на 104:

```bash
ssh root@203.0.113.10

# Xray жив и слушает public :443 + local API
systemctl is-active xray
ss -ltnp | grep -E '127\.0\.0\.1:10085|:443'

# client1 есть в clients ровно один раз
jq '[.inbounds[]?.settings.clients[]? |
  select(.id=="e04cf682-507f-55ba-89c9-45446c2d3e6a" or .email=="client1")
] | length' /etc/xray/config.json

# routing client1 должен вести в out-130
jq '.routing.rules[]? | select((.user // []) | index("client1"))' /etc/xray/config.json
```

Ожидаемо:

```text
xray active
client1 count = 1
outboundTag = out-130
```

## Killswitch на сервере 104 — должен пропускать цепочку client1 (важно!)

На 104 `out-130` использует публичный TCP до `198.51.100.130:10443` и ставит
socket mark `130` (`0x82`). Его fail-closed обеспечивают точные правила:

```text
-A OUTPUT -d 198.51.100.130/32 -p tcp --dport 10443 \
          -m mark --mark 0x82 -j ACCEPT
-A OUTPUT -m mark --mark 0x82 -j DROP
```

Правильная цель подключается, любая другая цель с mark `0x82` блокируется.
Интерфейс `wg130` на обоих серверах существует и используется другими/старыми
задачами, но текущий Xray outbound `out-130` к нему не привязан.

⚠️ Если на 104 пересобирать killswitch — **всегда** включать эти правила. Иначе пропадает не только интернет client1, но и админ-доступ: SSH-джамп `WSL → Aeza → 104` сам идёт через VPN как client1 (всё, кроме `104:443`, в TUN). Полный allow-лист killswitch — в `../AUDIT.md`.

## Killswitch в WSL для config 1

WSL killswitch находится здесь:

```text
/usr/local/bin/killswitch-vless-104
```

Смысл правил:

- default policy `DROP` для `INPUT/FORWARD/OUTPUT`;
- разрешён `lo`;
- разрешён `tun+`;
- через `eth0` разрешён только TCP к `203.0.113.10:443`;
- IPv6 через `ip6tables` закрыт;
- если TUN/VPN ломается, WSL не должен уходить напрямую через `eth0`.

В правилах намеренно остаётся общий `ESTABLISHED,RELATED`: запуск профиля не
должен принудительно обрывать соединения, которые могли понадобиться другой
задаче до включения VPN. Новые прямые соединения после запуска killswitch
блокируются; проверка `curl --interface eth0` должна давать timeout.

С 2026-08-19 владелец включил автозапуск постоянного профиля WSL→104→130.
`/etc/wsl.conf` detached-запускает `/usr/local/sbin/start-vless130-at-boot`,
который не дублирует уже здоровые процессы, делает до трёх попыток штатного
`/usr/local/bin/start-vless130` и требует exit `198.51.100.130`. Тот же
идемпотентный wrapper вызывается раз в минуту из `/etc/cron.d/vless130-health`
для восстановления после падения Xray/sing-box. Журнал ошибок/восстановлений:
`/var/log/vless130-boot.log`. При неуспехе killswitch остаётся fail-closed.

Проверка правил в WSL:

```bash
sudo iptables -S
sudo ip6tables -S
```

Ключевые ожидаемые строки:

```text
-P OUTPUT DROP
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -d 203.0.113.10/32 -o eth0 -p tcp --dport 443 -j ACCEPT
-P OUTPUT DROP     # в ip6tables тоже DROP
```

## WSL-тест killswitch

Запуск проверки:

```bash
cd /work/vpn/vless_xhttp/wsl_130

# Обычный выход должен идти через 130
curl -4 --max-time 15 -sS https://api.ipify.org ; echo
# ожидаемо: 198.51.100.130

# Прямой eth0 не должен выпускать наружу
curl --interface eth0 -4 --max-time 10 -sS https://api.ipify.org || echo DIRECT_ETH0_BLOCKED
# ожидаемо: DIRECT_ETH0_BLOCKED / timeout

# IPv6 не должен выходить
curl -6 --max-time 10 -sS https://api64.ipify.org || echo IPV6_BLOCKED
# ожидаемо: IPV6_BLOCKED / timeout

# eth0-bound DNS/HTTP не должны утекать
curl --interface eth0 --max-time 8 -sS telnet://1.1.1.1:53 </dev/null || echo ETH0_DNS_TCP_BLOCKED
curl --interface eth0 --max-time 8 -sS http://1.1.1.1/ || echo ETH0_HTTP_BLOCKED
```

## Тест падения локального WSL VPN-клиента

Имитация падения `sing-box` в WSL:

```bash
sudo kill $(cat /tmp/sing-vless130.pid)
sleep 2

curl -4 --max-time 10 -sS https://api.ipify.org || echo DEFAULT_BLOCKED_AFTER_SINGBOX_STOP
curl --interface eth0 -4 --max-time 10 -sS https://api.ipify.org || echo DIRECT_ETH0_STILL_BLOCKED
```

Ожидаемо: оба запроса не выходят наружу.

Вернуть `sing-box`:

```bash
nohup sudo /usr/local/bin/sing-box run \
  -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json \
  >> /tmp/sing-vless130.log 2>&1 & echo $! > /tmp/sing-vless130.pid

curl -4 --max-time 15 -sS https://api.ipify.org ; echo
# ожидаемо: 198.51.100.130
```

## Тест падения сервера 130 для config 1

Проверенный способ имитировать падение 130 — остановить на сервере 130 только Xray exit-сервис, который слушает публичный `0.0.0.0:10443`.

Важно:

- не выключать весь сервер 130;
- не выключать `wg130` и другие независимые сервисы: текущему `out-130` это не
  требуется, но они могут использоваться другими задачами;
- не трогать OpenVPN/DNS/slipstream на 130.

Отключить 130 exit Xray:

```bash
ssh root@198.51.100.130

systemctl stop xray
sleep 2
systemctl is-active xray || true
ss -ltnp | grep ':10443' || echo NO_10443_LISTENER
wg show wg130 | sed -n '1,20p'
```

Ожидаемо:

```text
xray inactive
NO_10443_LISTENER
wg130 still present
```

Проверить из WSL:

```bash
cd /work/vpn/vless_xhttp/wsl_130

curl -4 --max-time 15 -sS https://api.ipify.org || echo DEFAULT_BLOCKED_WHEN_130_XRAY_DOWN
curl --interface eth0 -4 --max-time 8 -sS https://api.ipify.org || echo DIRECT_ETH0_BLOCKED_WHEN_130_DOWN
curl -6 --max-time 8 -sS https://api64.ipify.org || echo IPV6_BLOCKED_WHEN_130_DOWN
```

Ожидаемо: запросы не выходят наружу, прямой `eth0` не используется.

Включить обратно на 130:

```bash
ssh root@198.51.100.130

systemctl start xray
sleep 3
systemctl is-active xray
ss -ltnp | grep ':10443'
```

После восстановления проверить WSL:

```bash
cd /work/vpn/vless_xhttp/wsl_130
curl -4 --max-time 25 -sS https://api.ipify.org ; echo
# ожидаемо: 198.51.100.130
```

Фактически проверено 2026-05-26:

- при остановке `xray.service` на 130 обычный WSL `curl` получил timeout;
- `curl --interface eth0` тоже получил timeout;
- IPv6 тоже не вышел;
- после `systemctl start xray` на 130 WSL снова показал `198.51.100.130`.

## Тест отключения config 1 на сервере 104 без рестарта Xray

На 104 включён локальный Xray API:

```text
127.0.0.1:10085
```

Полная инструкция лежит в соседнем документе:

```text
/work/vpn/vless_xhttp/API_CLIENT1_CONTROL.md
```

Быстрый тест отключения только config 1 (`client1`) через runtime routing:

```bash
ssh root@203.0.113.10

jq '.routing.rules |= map(
  if ((.user // []) | index("client1"))
  then .outboundTag = "block-v6" | .ruleTag = "client1-off-temporary"
  else .
  end
) | {routing}' /etc/xray/config.json > /tmp/xray-routing-client1-off.json

/opt/xray/xray api adrules \
  --server=127.0.0.1:10085 \
  /tmp/xray-routing-client1-off.json

/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

Ожидаемо: runtime rule для `client1` ведёт в `block-v6`; Xray не перезапускается; остальные клиенты не удаляются.

Включить config 1 обратно:

```bash
ssh root@203.0.113.10

jq '{routing: .routing}' /etc/xray/config.json > /tmp/xray-routing-client1-on.json

/opt/xray/xray api adrules \
  --server=127.0.0.1:10085 \
  /tmp/xray-routing-client1-on.json

/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

Проверка после включения:

```bash
cd /work/vpn/vless_xhttp/wsl_130
curl -4 --max-time 25 -sS https://api.ipify.org ; echo
# ожидаемо: 198.51.100.130
```
