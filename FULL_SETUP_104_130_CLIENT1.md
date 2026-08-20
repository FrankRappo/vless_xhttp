# Полная настройка client1: WSL -> 104 -> 130 без DNS/traffic leak

**Текущий статус 2026-08-19:** это активный и выбранный владельцем постоянный
WSL-профиль. Экспериментальная цепочка через 178 после canary возвращена на этот
маршрут из-за дополнительной сложности восстановления и нестабильности длинных
соединений.

Дата фиксации: 2026-06-29.

Этот документ описывает только полную рабочую настройку профиля `client1`. Пароли, UUID, private keys и другие секреты здесь не дублируются: они остаются в рабочих JSON/на VPS.

## 1. Цель

`client1` должен выходить в интернет с IP `198.51.100.130`.

Гарантия схемы:

- приложения в WSL идут в TUN `tun-vless130`;
- TUN отправляет трафик в локальный Xray SOCKS `127.0.0.1:10808`;
- Xray соединяется с VPS 104 на `203.0.113.10:443`;
- VPS 104 пересылает `client1` на VPS 130 `198.51.100.130:10443`;
- конечные сайты видят `198.51.100.130`, а не 104/194/WSL;
- если 130 недоступен, трафик должен timeout'иться, а не уходить мимо 130.

Важно: WSL -> `203.0.113.10:443` разрешён как транспортный канал. Это не означает, что конечные сайты видят 104. Конечные сайты должны видеть только 130.

## 2. Общая схема

```text
WSL applications
  -> sing-box TUN tun-vless130 / 172.19.130.1/30
  -> local Xray SOCKS 127.0.0.1:10808
  -> VPS 104: 203.0.113.10:443
  -> VPS 104 Xray outbound out-130, mark 130 / 0x82
  -> VPS 130: 198.51.100.130:10443
  -> Internet, exit IP 198.51.100.130
```

На VPS 104 есть отдельная существующая ветка через 194 со своим killswitch. Для `client1` её не трогать: изменение общих firewall/Xray правил на 104 может сломать другие конфиги.

## 3. Файлы WSL

Каталог проекта:

```text
/work/vpn/vless_xhttp
```

Основные файлы:

```text
/work/vpn/vless_xhttp/wsl_130/xray-client1-104.json
/work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
```

Локальные backup'ы sing-box:

```text
/work/vpn/vless_xhttp/wsl_130/backups/sing-box-tun-to-xray.before-dns-*.json
/work/vpn/vless_xhttp/wsl_130/backups/sing-box-tun-to-xray.before-dns-port53-*.json
```

## 4. WSL Xray

Процесс:

```bash
/usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_130/xray-client1-104.json
```

Локальный listener:

```text
127.0.0.1:10808 SOCKS5
```

Назначение:

- принимает трафик от sing-box;
- подключается к `203.0.113.10:443`;
- рабочие секреты находятся в `xray-client1-104.json` и в документ не вынесены.

Проверка:

```bash
pgrep -a xray
ss -ltnp | grep 10808
```

## 4.1. Маскировка WSL -> 104: старая настройка, не менялась

Маскировка на участке **WSL -> 104** осталась из старой версии и при переводе `out-130` на новый путь **не менялась**.

Текущая логика client1:

```text
Xray client1 -> vpn.example.com:443
/etc/hosts  -> vpn.example.com = 203.0.113.10
TCP         -> 203.0.113.10:443
Reality SNI -> vpn.example.com
xHTTP path  -> /news-api/v2
fingerprint -> chrome
```

То есть фактический TCP-коннект идёт на IP 104, потому что домен локально pinned через `/etc/hosts`, но доменное имя `vpn.example.com` остаётся в настройках `address`/Reality `serverName` и используется как маскировка handshake.

Ключевые поля старой маскировки в `wsl_130/xray-client1-104.json`:

```text
vnext.address: vpn.example.com
vnext.port: 443
streamSettings.network: xhttp
streamSettings.security: reality
realitySettings.serverName: vpn.example.com
realitySettings.fingerprint: chrome
xhttpSettings.path: /news-api/v2
xhttpSettings.mode: stream-one
```

Проверка pin'а:

```bash
grep -n 'vpn.example.com' /etc/hosts
```

Ожидаемо:

```text
203.0.113.10 vpn.example.com
```

Важно: это не отдельный "сначала запрос к сайту, потом к IP". Любой TCP идёт к IP, но домен остаётся в конфигурации Xray/Reality как маскировочное имя. Внешне участок WSL -> 104 остаётся тем же xHTTP/Reality профилем, который был раньше.

Участок **104 -> 130** устроен иначе: это server-to-server leg на `198.51.100.130:10443`, защищённый killswitch на 104 через mark `0x82`. Он не маскируется под сайт; его задача — жёстко довести `client1` только до 130 и не дать fallback мимо 130.
## 5. WSL sing-box TUN

Процесс:

```bash
/usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
```

TUN:

```text
interface: tun-vless130
address:   172.19.130.1/30
mtu:       9000
```

Ключевые настройки inbound:

```json
{
  "type": "tun",
  "tag": "tun-in",
  "interface_name": "tun-vless130",
  "address": ["172.19.130.1/30"],
  "mtu": 9000,
  "auto_route": true,
  "strict_route": true,
  "stack": "system"
}
```

Ключевые outbounds:

```json
[
  {
    "type": "socks",
    "tag": "xray-socks",
    "server": "127.0.0.1",
    "server_port": 10808,
    "version": "5"
  },
  { "type": "direct", "tag": "direct" },
  { "type": "block", "tag": "block" }
]
```

Ключевой route:

```json
{
  "auto_detect_interface": true,
  "final": "xray-socks",
  "rules": [
    {
      "port": 53,
      "network": ["tcp", "udp"],
      "action": "hijack-dns"
    },
    {
      "ip_cidr": ["203.0.113.10/32"],
      "outbound": "direct"
    }
  ]
}
```

Смысл:

- весь обычный трафик идёт в `xray-socks`;
- прямой outbound разрешён только для транспорта до `203.0.113.10`;
- DNS port 53 перехватывается внутри sing-box.

## 6. DNS без утечки

`/etc/resolv.conf` может оставаться таким:

```text
nameserver 1.1.1.1
nameserver 1.0.0.1
```

Но реальные DNS-пакеты port 53 не должны уходить напрямую: sing-box перехватывает их правилом `hijack-dns` и отправляет upstream как DoH через `xray-socks`.

Текущий DNS-блок в `sing-box-tun-to-xray.json`:

```json
{
  "servers": [
    {
      "type": "https",
      "tag": "google-doh-via-130",
      "server": "8.8.8.8",
      "server_port": 443,
      "path": "/dns-query",
      "detour": "xray-socks",
      "tls": {
        "enabled": true,
        "server_name": "dns.google"
      }
    }
  ],
  "rules": [
    {
      "action": "route",
      "server": "google-doh-via-130"
    }
  ],
  "final": "google-doh-via-130",
  "strategy": "ipv4_only",
  "cache_capacity": 4096
}
```

История изменения DNS: в старой версии здесь был Cloudflare DoH
`1.1.1.1` / `cloudflare-dns.com` с тем же `detour: xray-socks`.
После перезапуска WSL он давал cold-start `DNS/TLS timeouts`, поэтому
2026-06-29 upstream заменён на Google DoH `8.8.8.8` / `dns.google`.
Ключевой принцип не изменился: DNS upstream всё равно идёт только через
`xray-socks`, то есть через цепочку `WSL -> 104 -> 130`, а не напрямую.

Почему DNS не должен утекать:

1. DNS upstream имеет `detour: xray-socks`.
2. В sing-box нет прямого DNS через `direct`.
3. WSL firewall не разрешает `eth0` port 53/853.
4. Единственный разрешённый `eth0` egress — TCP к `203.0.113.10:443`.
5. DNS port 53 перехватывается `hijack-dns`.

Нельзя добавлять:

- DNS через `direct`;
- WSL `iptables` allow на `eth0` port 53/853;
- fallback DNS мимо `xray-socks`;
- изменение `/etc/resolv.conf` без повторной leak-проверки.

Официальные документы sing-box:

- https://sing-box.sagernet.org/configuration/dns/
- https://sing-box.sagernet.org/configuration/dns/server/https/
- https://sing-box.sagernet.org/configuration/shared/dial/
- https://sing-box.sagernet.org/configuration/route/rule_action/#hijack-dns

## 7. WSL killswitch

Текущая политика OUTPUT:

```text
-P OUTPUT DROP
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j ACCEPT
-A OUTPUT -d 203.0.113.10/32 -o eth0 -p tcp -m tcp --dport 443 -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

Смысл:

- прямой интернет через `eth0` запрещён;
- прямой DNS через `eth0` запрещён;
- разрешён только транспорт WSL -> 104:443;
- если 130/104/Xray/sing-box ломается, трафик должен зависнуть, а не выйти напрямую.

Общие правила `ESTABLISHED,RELATED` сохранены **осознанно**. Их назначение — не
обрывать уже существующие соединения и позволять использовать WSL для других
задач до включения VPN-профиля. Поэтому это operational killswitch для новых
соединений после запуска профиля, а не требование принудительно уничтожить все
сессии, открытые до запуска.

Killswitch также намеренно не включён в `/etc/wsl.conf` boot-command: владелец
запускает его через `/usr/local/bin/start-vless130`, когда нужен именно этот
профиль. После нового старта WSL до запуска wrapper разрешено использовать WSL
для других задач. Решение подтверждено владельцем 2026-08-18; не удалять
`ESTABLISHED,RELATED` и не включать автозапуск без отдельного запроса.

Проверка:

```bash
sudo iptables -S OUTPUT
curl -4 --interface eth0 --connect-timeout 5 --max-time 8 https://api.ipify.org
```

Ожидание для второго теста: timeout.

## 8. VPS 104

IP:

```text
203.0.113.10
```

Назначение:

- принимает `client1` на 443;
- отправляет `client1` на 130;
- не выпускает marked traffic `out-130` куда-либо кроме `198.51.100.130:10443`;
- не ломает отдельную ветку 104 -> 194.

Ключевые настройки `/etc/xray/config.json` на 104:

```text
outbound: out-130
target:   198.51.100.130:10443
mark:     130 decimal = 0x82 hex
mux:      disabled
```

Ключевое правило Xray outbound:

```json
"sockopt": {
  "mark": 130
}
```

Firewall на 104 для marked traffic:

```text
-A OUTPUT -d 198.51.100.130/32 -p tcp -m mark --mark 0x82 --dport 10443 -j ACCEPT
-A OUTPUT -m mark --mark 0x82 -j DROP
```

Проверки на 104:

```bash
iptables -vnL OUTPUT --line-numbers | grep -E '0x82|198.51.100.130|10443'
ss -tnp | grep '198.51.100.130:10443'
```

## 8.1. Явный killswitch на VPS 104 для `out-130`

Да: на 104 задействован отдельный killswitch именно для Xray outbound `out-130`.

Важно понимать границу: этот killswitch защищает **marked traffic** Xray `out-130`, то есть трафик, которому Xray ставит Linux mark `130` (`0x82`). Он не является общим запретом всего трафика VPS 104: на 104 уже есть другие сервисы и отдельная ветка через 194, поэтому общий firewall 104 менять нельзя без отдельного аудита.

Рабочая связка:

```text
Xray out-130 -> sockopt.mark = 130 -> iptables mark 0x82
```

Активные правила на 104:

```text
-A OUTPUT -d 198.51.100.130/32 -p tcp -m mark --mark 0x82 -m tcp --dport 10443 -j ACCEPT
-A OUTPUT -m mark --mark 0x82 -j DROP
```

Эти же правила сохранены в persistent firewall:

```text
/etc/iptables/rules.v4
```

Что это гарантирует для `client1`:

- если `out-130` идёт к `198.51.100.130:10443`, пакет разрешается;
- если marked traffic `out-130` пытается уйти на любой другой IP/порт, он попадает в DROP;
- если 130 отвалится, marked traffic не должен fallback'нуться через 104/194/direct;
- существующая ветка 104 -> 194 не должна ломаться, потому что эти правила матчят только mark `0x82`.

Проверка правил:

```bash
iptables -S OUTPUT | grep -E '0x82|130\.185\.249\.96|10443'
iptables -vnL OUTPUT --line-numbers | grep -E '0x82|130\.185\.249\.96|10443|Chain OUTPUT'
grep -nE '0x82|130\.185\.249\.96|10443' /etc/iptables/rules.v4
```

Активная проверка 2026-06-29 на 104:

```text
marked connect 198.51.100.130:10443 -> CONNECTED
marked connect 1.1.1.1:443       -> TimeoutError / DROP
DROP counter mark 0x82: 0 -> 4 packets
```

То есть проверка подтвердила: правильная цель 130:10443 разрешена, неправильная цель с тем же mark блокируется.

Минимальный тест вручную с 104:

```bash
python3 - <<'PY'
import socket, time
SO_MARK = getattr(socket, 'SO_MARK', 36)
MARK = 130
for dst, port in [('198.51.100.130', 10443), ('1.1.1.1', 443)]:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, SO_MARK, MARK)
    s.settimeout(4)
    t = time.time()
    try:
        s.connect((dst, port))
        print(dst, port, 'CONNECTED', round(time.time() - t, 3))
    except Exception as e:
        print(dst, port, 'FAILED/BLOCKED', type(e).__name__, e, round(time.time() - t, 3))
    finally:
        s.close()
PY
```

Ожидание:

```text
198.51.100.130 10443 CONNECTED
1.1.1.1 443 FAILED/BLOCKED TimeoutError
```

Если второй тест подключился, killswitch на 104 сломан и пользоваться `client1` нельзя до исправления.
## 9. VPS 130

IP:

```text
198.51.100.130
```

Назначение:

- принимает `out-130` от 104 на TCP `10443`;
- является конечным exit IP;
- **намеренно принимает подключения к TCP `10443` с любых внешних IP** — порт
  оставлен публичным для возможных будущих задач; доступ к VLESS по-прежнему
  требует действительный UUID.

Xray на 130 слушает:

```text
0.0.0.0:10443
```

Фактический active firewall на 130 (проверено 2026-08-18):

```text
INPUT policy ACCEPT
активных INPUT-правил для TCP 10443 нет
```

В `/etc/iptables/rules.v4` остаются старые строки `allow source 104` +
`drop остальных`, однако это **архивное/неактивное состояние**:
`iptables-persistent` и `netfilter-persistent` на 130 не установлены, файл при
старте не загружается. Единственный boot-firewall — `iptables-openvpn.service`,
и он правила `10443` не добавляет.

**Решение владельца от 2026-08-18:** оставить `198.51.100.130:10443` публично
доступным специально. Не устанавливать/не запускать `netfilter-persistent` с
текущим `rules.v4` без отдельного решения — это неожиданно закроет порт для
других источников.

Проверки на 130:

```bash
ss -ltnp | grep 10443
iptables -vnL INPUT --line-numbers | grep 10443
```

Ожидаемо: Xray слушает `0.0.0.0:10443`, а в active INPUT нет фильтра по source.
Проверка с 178 также должна подключаться к TCP-порту. Это считается нормой, а не
ошибкой периметра.

## 10. Backup и rollback

### WSL sing-box

Backup'ы:

```bash
ls -1 /work/vpn/vless_xhttp/wsl_130/backups/sing-box-tun-to-xray.before-*.json
```

Rollback:

```bash
cp -a /work/vpn/vless_xhttp/wsl_130/backups/<backup>.json \
  /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
/usr/local/bin/sing-box check -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
sudo pkill -f '/usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json'
nohup sudo /usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json \
  >/tmp/sing-box-vless130.log 2>&1 &
```

### 104

Backup'ы на 104:

```text
/root/omx-backups/104-xray-before-out130-public-*.json
/root/omx-backups/104-iptables-before-out130-public-*.v4
```

Rollback на 104 делать осторожно: там есть отдельная ветка через 194.

### 130

Backup'ы на 130:

```text
/root/omx-backups/130-xray-before-public10443-*.json
/root/omx-backups/130-iptables-before-public10443-*.v4
```

Rollback на 130 выполнять осторожно с сохранением публичной доступности
`:10443`; SSH возможен напрямую либо через существующую административную цепочку.

## 11. Запуск и рестарт WSL

Основной способ запуска WSL-профиля `client1` — тот же wrapper, которым ты пользовался раньше:

```bash
/usr/local/bin/start-vless130
```

Именно его считать штатной командой запуска.

Что делает `/usr/local/bin/start-vless130`:

1. Применяет WSL killswitch:

```bash
sudo /usr/local/bin/killswitch-vless-104
```

2. Останавливает старые процессы sing-box и Xray для этих config-файлов.
3. Запускает Xray:

```bash
/usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_130/xray-client1-104.json
```

4. Запускает sing-box:

```bash
/usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json
```

5. Проверяет, что Xray поднялся.
6. Прогревает Xray SOCKS без DNS через `--resolve api.ipify.org:443:104.26.13.205` и проверяет, что exit IP уже `198.51.100.130`.
7. Проверяет, что sing-box поднялся.
8. Прогревает TUN + DNS обычным `curl https://api.ipify.org` и ждёт рабочий exit IP `198.51.100.130`.
9. Только после этого печатает pin `vpn.example.com`, PID и строку `Запущено и проверено...`.

Зачем нужен warm-up: после холодного рестарта WSL первый DoH/TLS запрос может занимать дольше коротких browser/curl timeout'ов. Wrapper теперь не отдаёт управление как "готово", пока сам не проверит SOCKS, TUN и DNS через 130.

Логи wrapper'а:

```text
/tmp/xray-vless130.log
/tmp/sing-vless130.log
```

PID-файлы wrapper'а:

```text
/tmp/xray-vless130.pid
/tmp/sing-vless130.pid
```

Проверка после запуска:

```bash
pgrep -a xray
pgrep -a sing-box
ip -br addr show tun-vless130
curl -4 -sS --connect-timeout 8 --max-time 15 https://api.ipify.org ; echo
```

Ожидаемый IP:

```text
198.51.100.130
```

Проверка WSL killswitch после запуска:

```bash
sudo iptables -S OUTPUT
curl -4 --interface eth0 --connect-timeout 5 --max-time 8 https://api.ipify.org
```

Ожидание для forced `eth0`: timeout.

### Что делает `/usr/local/bin/killswitch-vless-104`

Этот скрипт является частью штатного запуска `/usr/local/bin/start-vless130`.

Он:

- pin'ит `vpn.example.com` на `203.0.113.10` в `/etc/hosts`;
- ставит `INPUT/FORWARD/OUTPUT DROP`;
- разрешает `lo`;
- разрешает `tun+`;
- разрешает через `eth0` только TCP к `203.0.113.10:443`;
- режет IPv6 через `ip6tables DROP`.

Смысл: WSL может напрямую по `eth0` соединяться только с 104:443 как транспортом Xray. Всё остальное должно идти через TUN или блокироваться.

### Ручной fallback, если wrapper нужно отладить

Обычно вручную запускать не нужно. Но если wrapper сломан, можно запустить теми же командами, которые он использует:

```bash
sudo /usr/local/bin/killswitch-vless-104

nohup sudo /usr/local/bin/xray run -c /work/vpn/vless_xhttp/wsl_130/xray-client1-104.json \
  >/tmp/xray-vless130.log 2>&1 &

nohup sudo /usr/local/bin/sing-box run -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json \
  >/tmp/sing-vless130.log 2>&1 &
```

Порядок важен: сначала killswitch, потом Xray, потом sing-box.
## 12. Обязательные тесты после изменений

⚠️ **Туннели тестируются на отдельном VPS, а не на рабочей машине.** Рабочая WSL — не
стенд: запуск `start-vless130` или ручной подъём другой цепочки гасит соседнюю цепочку,
поднимает свой TUN и рвёт живые соединения владельца. Проверку новой или изменённой
цепочки вести с постороннего VPS (подходит Aeza `203.0.113.20` — она вне VPN-пути
клиентов): положить туда клиентский конфиг, поднять SOCKS и сверить exit IP через
`curl --socks5-hostname`. Если проверять надо именно поведение WSL (killswitch,
DNS-hijack, TUN) — работать параллельно активной цепочке на отдельном SOCKS-порту
(у 130 это 10808, у 149 — 10809), TUN не переключать. Подробности — в
`FULL_SETUP_104_149_EXIT149.md`, раздел 8.

### Exit IP через TUN

```bash
curl -4 -sS --connect-timeout 8 --max-time 15 https://api.ipify.org
```

Ожидание:

```text
198.51.100.130
```

### DNS/TLS через TUN

```bash
for host in cloudflare.com one.one.one.one speed.cloudflare.com api.ipify.org; do
  printf '%-24s ' "$host"
  curl -4 -sS -o /dev/null --connect-timeout 7 --max-time 15 \
    -w 'dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total} ip=%{remote_ip}\n' \
    "https://$host/" || echo "rc=$?"
done
```

Ожидание: DNS/TLS проходит, постоянных DNS timeouts нет.

### Прямой eth0

```bash
curl -4 --interface eth0 --connect-timeout 5 --max-time 8 https://api.ipify.org
```

Ожидание: timeout.

### DNS leak

Если есть `tcpdump`:

```bash
sudo tcpdump -ni eth0 'udp port 53 or tcp port 53 or tcp port 853'
```

Во время DNS-запросов на `eth0` не должно быть DNS-пакетов.

Если `tcpdump` не установлен:

```bash
sudo iptables -S OUTPUT
```

Проверить, что нет allow для `eth0` port 53/853.

### Логи DNS hijack

```bash
grep -E 'inbound packet connection to (1\.1\.1\.1|1\.0\.0\.1):53|outbound connection to 1\.1\.1\.1:443|dns: exchanged' \
  /tmp/sing-box-vless130.log | tail -40
```

Нормальная картина:

- приложение пытается к `1.1.1.1:53` или `1.0.0.1:53`;
- sing-box перехватывает DNS;
- upstream идёт как DoH `1.1.1.1:443` через `xray-socks`;
- появляются `dns: exchanged ...`.

## 13. Последняя проверка после DNS/warm-up изменения

Последнее изменение: 2026-06-29 после рестарта WSL.

Что изменено:

- DNS upstream в `sing-box-tun-to-xray.json`: Cloudflare DoH -> Google DoH.
- `detour` не изменён: `google-doh-via-130` использует `xray-socks`.
- `/usr/local/bin/start-vless130` теперь прогревает Xray SOCKS и TUN/DNS перед завершением.
- Killswitch WSL не ослаблялся: direct `eth0` по-прежнему разрешён только к `203.0.113.10:443`.

Проверка config:

```text
sing-box check -c /work/vpn/vless_xhttp/wsl_130/sing-box-tun-to-xray.json -> OK
bash -n /usr/local/bin/start-vless130 -> OK
```

Запуск после изменения, включая проверку после `wsl.exe --terminate Ubuntu-24.04`:

```text
/usr/local/bin/start-vless130
Xray SOCKS прогрет: exit IP 198.51.100.130
TUN + DNS готовы: exit IP 198.51.100.130
Запущено и проверено: WSL -> 104 -> 130, DNS через туннель, exit IP 198.51.100.130.
real 0m11.625s после холодного старта WSL
```

Exit IP через default/TUN:

```text
curl https://api.ipify.org -> 198.51.100.130
5 повторов -> 198.51.100.130 каждый раз
```

DNS/TLS через default/TUN после cold-start warm-up:

```text
api.ipify.org          code=200 time=0.304623
cloudflare.com         code=301 time=0.368847
github.com             code=200 time=0.644778
speed.cloudflare.com   code=200 time=0.340909
```

Forced direct `eth0`:

```text
curl --interface eth0 https://api.ipify.org -> timeout
```

Скорость малым тестом:

```text
speed.cloudflare.com 20MB -> 20,000,000 bytes за 2.698397s, ~7.4 MB/s
```

Логи sing-box после warm-up:

```text
DNS errors since restart: none
DNS success examples: api.ipify.org 321ms, cloudflare.com 92ms, github.com 76ms
```

Ограничение проверки: `tcpdump` в WSL не установлен, поэтому DNS leak подтверждён по iptables policy, `eth0` timeout и sing-box logs, а не packet capture.

## 14. Что нельзя менять без полного retest

Не менять без повторения тестов из раздела 12:

1. WSL OUTPUT default DROP.
2. WSL allow только на `203.0.113.10:443` через `eth0`.
3. sing-box `route.final = xray-socks`.
4. sing-box DNS `detour = xray-socks`.
5. sing-box DNS hijack на port 53.
6. 104 Xray `out-130.sockopt.mark = 130`.
7. 104 firewall mark `0x82` allow/drop.
8. 130 `:10443` намеренно публичен для других задач; авторизация обеспечивается
   VLESS UUID. Старые restrictive-правила в `rules.v4` не активны и не должны
   загружаться автоматически без нового решения владельца.
9. Существующую ветку 104 -> 194.

## 15. Короткая формула проверки

Если всё работает правильно:

```bash
curl -4 https://api.ipify.org
# 198.51.100.130

curl -4 --interface eth0 --connect-timeout 5 --max-time 8 https://api.ipify.org
# timeout
```

Итог: `client1` должен показывать IP 130; DNS должен идти через sing-box DoH -> xray-socks -> 104 -> 130; при отказе 130 трафик должен остановиться, а не уйти через 104/194/direct.
