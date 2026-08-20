# Полная настройка exit149: WSL -> 104 -> 149 без DNS/traffic leak

Дата ввода: 2026-07-24. Построено по образцу [`FULL_SETUP_104_130_CLIENT1.md`](./FULL_SETUP_104_130_CLIENT1.md).

Секреты (пароли серверов) здесь не дублируются, они в `AUDIT.md` и в рабочих JSON.

## 1. Цель

Профиль `exit149` должен выходить в интернет с IP `203.0.113.40`.

Гарантия схемы:

- приложения в WSL идут в TUN `tun-vless149`;
- TUN отправляет трафик в локальный Xray SOCKS `127.0.0.1:10809`;
- Xray соединяется с VPS 104 на `203.0.113.10:443`;
- VPS 104 пересылает `exit149` на VPS 149 `203.0.113.40:10443`;
- конечные сайты видят `203.0.113.40`, а не 104/194/130/WSL;
- если 149 недоступен, трафик должен timeout'иться, а не уходить мимо 149.

Это независимая ветка: цепочка `client1 -> out-130 -> 130` и общий пул `tunnel-1..10 -> 194` не затронуты.

## 2. Общая схема

```text
WSL applications
  -> sing-box TUN tun-vless149 / 172.19.149.1/30
  -> local Xray SOCKS 127.0.0.1:10809
  -> VPS 104: 203.0.113.10:443   (Reality SNI vpn.example.com, xHTTP /news-api/v2)
  -> VPS 104 Xray outbound out-149, mark 149 / 0x95
  -> VPS 149: 203.0.113.40:10443
  -> Internet, exit IP 203.0.113.40
```

## 3. Файлы WSL

```text
/work/vpn/vless_xhttp/wsl_149/xray-exit149-104.json      # локальный Xray, SOCKS 10809
/work/vpn/vless_xhttp/wsl_149/sing-box-tun-to-149.json   # TUN tun-vless149 -> SOCKS
/work/vpn/vless_xhttp/wsl_149/exit149.txt                # vless-ссылка №1
/work/vpn/vless_xhttp/wsl_149/exit149-2.txt              # vless-ссылка №2
```

На новый выход заведено **два клиента** — чтобы раздать на два устройства и различать их
в access-логе 104. Оба идут одним и тем же маршрутом `out-149` и дают один exit IP:

| Ссылка | Пользователь | UUID | shortId |
|--------|--------------|------|---------|
| `exit149.txt` | `exit149` | `a6eb5598-6648-5697-b2a7-8bc8c4432b17` | `01010101` |
| `exit149-2.txt` | `exit149-2` | `eafe4941-6ae7-58ac-b2cf-6c64cfae47fc` | `01010101` |

Ссылки для мобильных приложений (v2RayTun / Streisand / NekoBox) лежат в двух местах:
`wsl_149/` рядом с конфигами и `clients/` вместе с остальными клиентскими ссылками.
Файлы идентичны; при перевыпуске UUID обновлять обе копии.

Локальный конфиг Xray в WSL (`xray-exit149-104.json`) использует первого пользователя
(`exit149`); вторая ссылка предназначена для второго устройства.

## 4. Новый сервер 149 (exit)

| Параметр | Значение |
|----------|----------|
| IPv4 | `203.0.113.40` |
| Провайдер | Vultr (AS20473) |
| OS | Debian 12 bookworm |
| Ресурсы | 1 vCPU / 451 MB RAM / 8.9 GB disk, swap нет |
| SSH | root, порт 22, пароль — в `AUDIT.md` |
| Xray | 26.3.27 (официальный installer) |
| Конфиг | `/usr/local/etc/xray/config.json` |
| Unit | `xray.service` (enabled) |
| Логи | `/var/log/xray/{access,error}.log` |

Inbound на 149:

```text
tag:      in-from-104
listen:   0.0.0.0:10443
protocol: vless, security none, network tcp
user id:  d7e2c5eb-... (лег 104->149, в конфиге на 104 и на 149)
sockopt:  tcpKeepAliveIdle 15 / tcpKeepAliveInterval 10
```

Outbound: `freedom` с `domainStrategy: UseIPv4`; IPv6 назначения -> `blackhole`.

Firewall (ufw, default deny incoming):

```text
22/tcp     ALLOW IN  Anywhere
10443/tcp  ALLOW IN  203.0.113.10      # только с entry-узла
```

Проверка снаружи (с третьего хоста, не с 104): `10443` должен быть timeout.

## 5. VPS 104 — что добавлено

Всё применено **вживую через Xray API, без рестарта** (pid Xray не менялся), затем продублировано на диск.

1. Outbound `out-149` (клон `out-130`):

```text
target:  203.0.113.40:10443
network: tcp, security none
mark:    149 decimal = 0x95 hex
mux:     disabled
```

2. Пользователи `exit149` (uuid `80ef98b5-...`) и `exit149-2` (uuid `a66ea51e-...`) на
   inbound `in-reality-xhttp`, оба с shortId `01010101`.

3. Routing-правило `ruleTag: exit149-out` — **до** catch-all балансера, в нём оба
   пользователя: `"user": ["exit149", "exit149-2"]`:

```text
block-v6 -> out-130(client1) -> direct-104(exit104) -> out-149(exit149, exit149-2) -> tunnel-balancer(остальные)
```

Третий и следующие клиенты на этот выход заводятся так же: `adu` с новым uuid + `adrules`
с дописанным email в `user` того же правила. Нового outbound и новых iptables-правил не нужно.

4. Killswitch для marked traffic (вставлен сразу после пары 0x82):

```text
-A OUTPUT -d 203.0.113.40/32 -p tcp -m mark --mark 0x95 -m tcp --dport 10443 -j ACCEPT
-A OUTPUT -m mark --mark 0x95 -j DROP
```

Сохранено в `/etc/iptables/rules.v4` через `netfilter-persistent save`.
Бэкапы: `/etc/xray/config.json.bak-20260724-221011Z`, `/etc/iptables/rules.v4.bak-before-out149-*`.

5. `/root/balancer-leak-check.sh` расширен на четвёртый маршрут: теперь ловит
`обычный->149`, `exit149*->194/130/104` и симметричные нарушения. Карта выходов вынесена
в переменную `EXPECT` в начале скрипта (`client1=out-130 exit104=direct-104
exit149=out-149 exit149-2=out-149`).

⚠️ **Заводите нового персонального клиента — допишите его в `EXPECT`.** Иначе сторож
считает его обычным клиентом и при первом же коннекте выдаст ложный `EXIT-IP LEAK`.

Бэкапы: `/root/balancer-leak-check.sh.bak-20260724-221604Z`, `...bak2-*`.
Проверено самотестом на подложном логе: `client29->out-149` и `exit149-2->tunnel-3`
ловятся, штатные маршруты и `block-v6` ложных срабатываний не дают.

⚠️ Инвариант соблюдён: тег `out-149` **не** начинается с `tunnel-`, пул балансера остался ровно `tunnel-1..10`.

## 6. Запуск в WSL

⚠️ **Враппера `start-vless149` на машине нет — по решению владельца он удалён 2026-07-24.**
Штатный враппер только один, `/usr/local/bin/start-vless130`, и он поднимает цепочку 130.
Переключение на 149 делается вручную и только осознанно: оно гасит цепочку 130 и уводит
весь трафик машины на новый выход. Для проверки самого конфига переключать TUN не нужно —
см. раздел 8.

Ручное переключение на 149:

```bash
# 1. killswitch (тот же, транспорт не изменился — только 104:443)
sudo /usr/local/bin/killswitch-vless-104

# 2. погасить цепочку 130 (обе поднимают TUN с auto_route, вместе не работают)
sudo pkill -f 'wsl_130/sing-box-tun-to-xray.json'
sudo pkill -f 'wsl_130/xray-client1-104.json'

# 3. поднять Xray (SOCKS 10809), затем sing-box (TUN tun-vless149). Порядок важен.
nohup sudo /usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_149/xray-exit149-104.json \
  > /tmp/xray-vless149.log 2>&1 &
sleep 2
curl -4 -sS --socks5 127.0.0.1:10809 --resolve api.ipify.org:443:104.26.13.205 \
  --max-time 15 https://api.ipify.org   # прогрев, ожидается 203.0.113.40

nohup sudo /usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_149/sing-box-tun-to-149.json \
  > /tmp/sing-vless149.log 2>&1 &
sleep 2
curl -4 -sS --max-time 25 https://api.ipify.org   # ожидается 203.0.113.40
```

Возврат на цепочку 130:

```bash
sudo pkill -f 'wsl_149/sing-box-tun-to-149.json'
sudo pkill -f 'wsl_149/xray-exit149-104.json'
/usr/local/bin/start-vless130
```

Логи при ручном запуске: `/tmp/xray-vless149.log`, `/tmp/sing-vless149.log`.

## 7. DNS

Тот же принцип, что и в цепочке 130: DoH `8.8.8.8` / `dns.google` с `detour: xray-socks`,
port 53 перехватывается `hijack-dns`, прямого DNS через `direct` нет.
Единственный разрешённый прямой egress через `eth0` — TCP к `203.0.113.10:443`.

## 8. Обязательные тесты

⚠️ **Главное правило: туннели тестируются на отдельном VPS, а не на рабочей машине.**
Рабочая WSL-машина владельца — не стенд. Любая проверка новой или изменённой цепочки
(новый exit, смена транспорта, DNS, killswitch) делается с отдельного тестового VPS,
который выступает клиентом. На рабочей WSL не поднимать тестовые TUN, не гасить активную
цепочку и не запускать враперы ради проверки: это рвёт живые соединения владельца.

Тестовый хост: любой посторонний VPS с доступом наружу. Из имеющихся подходит Aeza
`203.0.113.20` — она не входит в VPN-путь клиентов (несёт только НЕ-VPN сервисы,
`OPERATIONS.md` §2), поэтому проверка с неё ничего рабочего не задевает. С неё же
проверяется периметр exit-узла (что `10443` закрыт для всех, кроме 104).

Схема теста с отдельного VPS: положить туда клиентский конфиг Xray, поднять SOCKS,
сходить `curl --socks5-hostname` и сверить exit IP. TUN там не нужен — SOCKS достаточно,
чтобы проверить всю цепочку `клиент -> 104 -> exit`.

```bash
# на тестовом VPS: клиентский конфиг + SOCKS, TUN не поднимаем
nohup xray run -c /root/xray-exit149-104.json > /tmp/xray-test149.log 2>&1 &
curl -4 -sS --socks5-hostname 127.0.0.1:10809 --max-time 20 https://api.ipify.org  # 203.0.113.40

# периметр exit-узла с постороннего хоста: порт должен быть закрыт
timeout 6 bash -c 'cat < /dev/null > /dev/tcp/203.0.113.40/10443' || echo "10443 закрыт (правильно)"
```

Исключение — когда проверить надо именно поведение самой WSL (killswitch, DNS-hijack,
TUN). Тогда работать только параллельно активной цепочке: поднять её локальный Xray на
своём SOCKS-порту (10809 для 149, 10808 занят цепочкой 130) и ходить через
`--socks5-hostname`, **не трогая TUN**.

```bash
nohup sudo /usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_149/xray-exit149-104.json \
  > /tmp/xray-vless149.log 2>&1 &
curl -4 -sS --socks5-hostname 127.0.0.1:10809 --max-time 20 https://api.ipify.org  # 203.0.113.40
curl -4 -sS --socks5-hostname 127.0.0.1:10808 --max-time 20 https://api.ipify.org  # 198.51.100.130
sudo pkill -f 'xray-exit149-104.json'   # осторожно: шаблон pkill -f попадает и в свою же
                                        # командную строку bash, можно убить свою сессию
```

После штатного переключения на 149 (когда оно действительно нужно):

```bash
# exit IP через TUN
curl -4 -sS --connect-timeout 8 --max-time 15 https://api.ipify.org      # 203.0.113.40

# прямой eth0
curl -4 --interface eth0 --connect-timeout 5 --max-time 8 https://api.ipify.org   # timeout
```

Killswitch marked traffic на 104 (выполнять на 104):

```bash
python3 - <<'PY'
import socket, time
SO_MARK = getattr(socket, 'SO_MARK', 36)
for dst, port in [('203.0.113.40', 10443), ('1.1.1.1', 443)]:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, SO_MARK, 149); s.settimeout(5)
    t = time.time()
    try:
        s.connect((dst, port)); print(dst, port, 'CONNECTED', round(time.time()-t, 2))
    except Exception as e:
        print(dst, port, 'BLOCKED', type(e).__name__, round(time.time()-t, 2))
    finally:
        s.close()
PY
```

Ожидание: `203.0.113.40:10443 CONNECTED`, `1.1.1.1:443 BLOCKED`.

Фактическая проверка 2026-07-24:

```text
xray -test (104, диск)                      Configuration OK
xray pid на 104 до/после                     1011645 / 1011645 (рестарта не было)
marked connect 203.0.113.40:10443            CONNECTED 0.07s
marked connect 1.1.1.1:443 (mark 149)        BLOCKED TimeoutError
marked connect 198.51.100.130:10443 (m.130)  CONNECTED (ветка 130 цела)
10443 на 149 с постороннего хоста (Aeza)     timeout (закрыт)
exit IP через SOCKS 10809                    203.0.113.40
exit IP через SOCKS 10808 (цепочка 130)      198.51.100.130
access-лог 104: exit149                      1/1 коннект -> out-149, посторонних нет
balancer-leak-check                          pool=ok leaks=normal:0,client1:0,exit104:0,exit149:0
обычные клиенты после правки                 идут через tunnel-1..10 (client29 и др.)
```

Добавление второго клиента `exit149-2`, проверка 2026-07-24 23:25 UTC:

```text
xray -test (104, диск)                       Configuration OK
xray pid до/после                            1011645 / 1011645 (рестарта не было)
adu exit149-2                                result: ok, Added 1 user(s)
правило exit149-out                          user = [exit149, exit149-2] -> out-149
inbounduser exit149-2                        uuid a66ea51e-... на месте
balancer-leak-check                          pool=ok, все счётчики 0, awk-ошибок нет
самотест сторожа на подложном логе           client29->out-149 и exit149-2->tunnel-3 пойманы
```

Живой трафик через второй UUID на момент записи не гонялся — ссылка выдана, но ещё
не использовалась. Первый коннект стоит сверить по access-логу:
`grep 'email: exit149-2' /var/log/xray-access.log | tail` — должен идти только в `out-149`.

## 9. Что нельзя менять без полного retest

1. WSL OUTPUT default DROP и allow только `203.0.113.10:443` через `eth0`.
2. sing-box `route.final = xray-socks`, DNS `detour = xray-socks`, hijack-dns на port 53.
3. 104: `out-149.sockopt.mark = 149` и пара iptables-правил на `0x95`.
4. 104: положение правила `exit149-out` — строго ДО правила балансера.
5. 149: ufw allow `10443/tcp` только с `203.0.113.10`.
6. Существующие ветки `client1 -> out-130` и `tunnel-1..10 -> 194`.
7. Имя тега: любой новый спец-выход именовать `out-*`/`exit-*`, НИКОГДА `tunnel-*`
   (селектор балансера префиксный — см. инцидент 2026-06-04 в `README.md`).

## 10. Открытые вопросы по 149

- На 149 нет swap (451 MB RAM) — для одного Xray хватает, но при росте нагрузки стоит добавить 1 GB.
- SSH на 149 открыт наружу на 22 с парольной аутентификацией и без fail2ban — как на остальных узлах.
  Если сервер становится постоянным, имеет смысл ключи + fail2ban.
- Нет watchdog'а/автовосстановления на 149 (на 104 это `xray-watchdog.sh`).
- Нет logrotate для `/var/log/xray/access.log` на 149.
