# Полный аудит конфигурации (актуализирован 2026-08-20)

Этот файл — финальный чек-лист **реального состояния серверов** для воспроизведения после disaster recovery.

---

## Серверы и доступы

| Что | Где |
|-----|-----|
| **Cloudzy admin panel** | https://cloudzy.com (логин владельца, не задокументирован здесь) |
| **Njalla account** | https://njal.la (логин владельца). API token: `<LOCAL_DNS_TOKEN_PATH>` |
| **Cloudflare account** | https://cloudflare.com (логин владельца). API token: `<LOCAL_CLOUDFLARE_TOKEN_PATH>` (3 разных — `Edit zone DNS` + `cjd-wales-admin` + `cjd-wales-full`) |
| **New VPS root** | `ssh root@203.0.113.10` пароль `<REDACTED_PASSWORD>` (порт 22) |
| **Server2 root** | `ssh -p 56777 root@203.0.113.30` пароль `<REDACTED_PASSWORD>` |
| **Exit 149 root** (добавлен 2026-07-24) | `ssh root@203.0.113.40` пароль `<REDACTED_PASSWORD>` (порт 22). Vultr, Debian 12. Exit для профиля `exit149`, см. `FULL_SETUP_104_149_EXIT149.md` |
| **Aeza root / China relay** | `ssh root@203.0.113.20` пароль `<REDACTED_PASSWORD>`. С 2026-08-18: первый VPN-hop из Китая и jump-хост к 104. Старые туннели Aeza→Server2 остаются демонтированы; независимые сервисы `tg-gemma-bot`, `llm-srv1-forward`, anydesk/x11vnc/rudesktop сохраняются — **сервер гасить нельзя** |
| **Exit 130 root** | Штатный админ-путь: сначала entry через relay, затем `ssh root@10.0.3.1` по private WireGuard; пароль `<REDACTED_PASSWORD>`. Public example: `198.51.100.130:22`. |

> **Доступ по SSH (2026-06-01):** прямой SSH из РФ-сети на 104 часто ресетится DPI на kex — заходить джампом через Aeza: `ssh -o ProxyCommand="ssh -W %h:%p root@203.0.113.20" root@203.0.113.10`. Server2 — только через 104 по `tunnel_key` на порт 56777 (снаружи :56777 закрыт).
> **Доступ к exit 130:** relay → entry → private WireGuard; уже находясь на entry, выполнять `ssh root@10.0.3.1`. Используйте отдельный непубликуемый пароль.

---

## NEW VPS (entry, 203.0.113.10) — полный inventory

### Listening ports

| Port | Service | Описание |
|------|---------|----------|
| 22 | sshd | Управление |
| 80 | nginx | LE challenge + HTTP-блог |
| 443 | xray | VLESS+Reality+XHTTP (вход для клиентов) |
| 127.0.0.1:8443 | nginx | HTTPS-блог (Reality dest) |
| 127.0.0.1:10443-10452 | autossh (10 шт) | local-side SSH-туннелей к Server2 |
| 127.0.0.1:19190 | node_exporter | Prometheus metrics (предустановлен Cloudzy, opt-out если не нужен) |
| 127.0.0.53:53 | systemd-resolve | системный DNS-cache (только localhost) |

### Services

| Сервис | Назначение |
|--------|-----------|
| `xray.service` | Главный VPN-сервер |
| `nginx.service` | Reverse-блог |
| `ssh-forward.service`, `ssh-forward-2.service` … `ssh-forward-10.service` | 10 autossh-туннелей к Server2:56777 |
| `fail2ban.service` | Защита :22 от брутфорса (jail `sshd`) |
| `ufw.service` | Firewall (INCOMING + OUTGOING killswitch) |
| `cron.service` | Запуск watchdog'ов |

### Файлы конфигурации

| Файл | Назначение |
|------|-----------|
| `/etc/xray/config.json` | Xray (11 outbounds, 1 inbound :443, 1 balancer, 2 routing rules) |
| `/etc/xray/reality.priv` | Reality x25519 priv key |
| `/etc/xray/reality.pub` | Reality x25519 pub key |
| `/etc/xray/clients_new.txt` | 32 UUIDs боевых клиентов |
| `/etc/xray/short_ids.txt` | 8 shortIds |
| `/etc/systemd/system/xray.service` | Xray systemd unit |
| `/etc/systemd/system/ssh-forward.service` (×10) | autossh systemd units |
| `/etc/nginx/sites-enabled/default` | nginx :80 |
| `/etc/nginx/sites-enabled/blog-internal` | nginx 127.0.0.1:8443 HTTPS |
| `/etc/letsencrypt/live/vpn.example.com/` | LE cert (auto-renew) |
| `/root/.ssh/tunnel_key` (priv) + `.pub` | SSH ключ к Server2 |
| `/root/tunnel-cleanup.sh` | Watchdog 30-сек (Send-Q/RTT/retransmit) |
| `/root/xray-watchdog.sh` | Watchdog 2-мин (process/port/RSS/FD) + вызов `balancer-leak-check.sh` |
| `/root/balancer-leak-check.sh` | Страж exit-IP утечек (инвариант пула `tunnel-1..10` + `tail` access-лога). Алерты → `journalctl -t balancer-leak-check`; liveness → `/run/balancer-leak-check.heartbeat` (~73B, tmpfs, перезапись). Добавлен 2026-06-04 |
| `/etc/logrotate.d/xray` | Ротация access-лога: daily/14/compress/**copytruncate**/su root root (без рестарта xray). Добавлен 2026-06-04 |
| `/var/log/xray-access.log` | Access log Xray (ротируется logrotate, `xray-access.log-YYYYMMDD[.gz]`) |
| `/etc/iptables/rules.v4`, `rules.v6` | iptables-persistent (включая ICMP правило) |
| `/var/www/html/` | Блог-контент (index.html + articles/) |

### Xray config — что внутри

- **DNS:** servers `[1.1.1.1, 8.8.8.8, https+local://1.1.1.1/dns-query]`, queryStrategy `UseIPv4`
- **Inbound `in-reality-xhttp` :443:** VLESS+Reality+XHTTP **`mode: auto`**, path `/news-api/v2`, **40 клиентов** (включая `relay178-test` и `relay178-130`), 8 shortIds. `relay178-test` идёт catch-all → `tunnel-1…10` → 194; `relay178-130` имеет отдельное правило → `out-130` → 130. TCP keepalive `{idle:15, interval:10}`.
- **Outbounds (11):**
  - `tunnel-1` … `tunnel-10`: VLESS к `127.0.0.1:10443-10452`, UUID `65116ee4-ed08-5880-8d46-b52b8f6b9513`, Mux concurrency=2, xudpConcurrency=4, xudpProxyUDP443=allow
  - `block-v6`: blackhole
  - `out-130`: VLESS TCP к публичному `198.51.100.130:10443`, `mux=false`, `sockopt.mark=130` (`0x82`). Active iptables на 104 разрешает этот mark только к точной цели `130:10443`, затем дропает mark на любой другой destination. `wg130` существует отдельно, но текущий Xray `out-130` его не использует. **Тег `out-*`, НЕ `tunnel-*`** — иначе попадёт в префиксный selector балансера.
  - **`direct-104`** (с 2026-06-01): `freedom`, `domainStrategy=UseIPv4`, `sockopt.mark=104` — выход напрямую через сам 104. Killswitch пропускает этот трафик правилом `OUTPUT -m mark --mark 104 -j ACCEPT`; немаркированные утечки по-прежнему блокируются.
- **Routing:**
  - IPv6 (`::/0`) → `block-v6`
  - TCP/UDP всё → `tunnel-balancer`
- **Balancer:** `tunnel-balancer`, selector `["tunnel-"]`, strategy `random`. ⚠️ Selector матчит теги **по префиксу** (`HasPrefix`) — в пул попадают ВСЕ outbound'ы с тегом `tunnel-*`. Поэтому персональные выходы (client1, exit104 и т.п.) обязаны называться вне префикса `tunnel-` (`out-*`/`exit-*`), иначе random-балансер начнёт случайно гнать через них обычных клиентов. **Инвариант: пул = ровно `tunnel-1..10`.**

### Reality keys (актуальные)

```
privateKey: REPLACE_WITH_X25519_PRIVATE_KEY
publicKey:  4k6nwJzR1r6XU8SLjDvCtSxDiIZt2gniTCwTbax5fEA
```

### Killswitch — iptables-persistent (с 2026-06-01; ufw удалён)

> **ВАЖНО:** `ufw` снесён как пакет (состояние `rc`, только конфиги). Переустановка `ufw` удалила бы `iptables-persistent`+`netfilter-persistent` (конфликт) — НЕ ставить ufw. Killswitch живёт в `/etc/iptables/rules.v4`+`rules.v6`, грузится `netfilter-persistent` (enabled) при каждом старте. Правка: бэкап `rules.v4.bak-*`, применять атомарно `iptables-restore` (живой трафик и conntrack не рвутся), для надёжности — страховочный `systemd-run --on-active=... ufw/iptables-restore` на возврат бэкапа.

**Default policy:** `DROP` на INPUT / OUTPUT / FORWARD

**Allowed IN:** lo, established/related, `wg130` (интерфейс), `198.51.100.130:51821/udp` (WG), 22/tcp, 80/tcp, 443/tcp; (INVALID → drop); ICMP

**Allowed OUT:**
- on `lo`
- on `wg130` (интерфейс) + `203.0.113.30:56777/tcp` (10 SSH-туннелей) + `198.51.100.130:51821/udp` (отдельный WireGuard к 130; текущий Xray `out-130` использует public TCP, не WG)
- 53/udp+tcp — DNS
- 80/tcp — HTTP (apt + LE challenge)
- 443/tcp — HTTPS (apt + LE ACME + DoH)
- 123/udp — NTP
- ICMP
- established/related

⚠️ **Путь client1 защищает пара mark-правил:** `0x82 + 198.51.100.130:10443 → ACCEPT`, затем любой другой `0x82 → DROP`. WG-allow (`wg130`, UDP `51821`) остаётся для независимых задач и не является текущим маршрутом Xray client1. v6: policy DROP.

### Exit 130: публичность `10443` — намеренное решение

Проверка 2026-08-18 показала: Xray слушает `0.0.0.0:10443`, active INPUT policy
`ACCEPT`, source-IP правил для `10443` нет; соединение с 178 проходит. В
`/etc/iptables/rules.v4` есть старые allow-104/drop-others строки, но
`iptables-persistent`/`netfilter-persistent` не установлены, а активный
`iptables-openvpn.service` их не загружает.

Решение владельца: **оставить порт публичным специально**, чтобы его можно было
использовать в других задачах. Не считать это leak и не загружать старые
restrictive-правила автоматически. Доступ к Xray требует действительный VLESS
UUID.

**Переживает перезагрузку 104** (проверено по enable-флагам): `netfilter-persistent`=enabled (грузит killswitch), `wg-quick@wg130`=enabled (WG к 130), `xray`=enabled, `ssh-forward*`=enabled. Дедлока нет — killswitch пропускает WG-хендшейк `130:51821`, loopback и `194:56777`, поэтому все сервисы поднимаются сквозь DROP-политику.

**Текущее состояние WSL (2026-08-19):** активны `/usr/local/bin/killswitch-vless-104`, профиль `wsl_130` и выход 130 через 104. Автозапуск закреплён в `/etc/wsl.conf` через `/usr/local/sbin/start-vless130-at-boot`; wrapper проверяет ожидаемый exit и оставляет killswitch fail-closed при неуспехе, а `/etc/cron.d/vless130-health` повторяет проверку раз в минуту. Владелец решил оставить эту схему постоянной. Профиль через 178, TLS ClientHello fragment `50-100` / `1-3`, supervisor и `/usr/local/bin/killswitch-vless-178` сохранены как canary/резерв, но не активны. Кандидатный killswitch разрешает `eth0` только к `203.0.113.20:443` и блокирует IPv6; применять его при текущем `wsl_130` нельзя. Расширенный тест выявил отдельные timeout, обрыв длинной загрузки и более сложное восстановление после рестарта 178.

### Crontab (root)

```
* * * * * /root/tunnel-cleanup.sh
* * * * * sleep 30 && /root/tunnel-cleanup.sh
*/2 * * * * /root/xray-watchdog.sh
```

### SSH-key для туннелей

`/root/.ssh/tunnel_key.pub`:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY_PUBLIC_KEY_REPLACE_ME tunnel-from-newvps@203.0.113.10
```

Зарегистрирован в `/root/.ssh/authorized_keys` на Server2.

### Блог-контент

`/var/www/html/`:
- `index.html` — главная (3 статьи с превью)
- `style.css` — стили
- `articles/mountains.html` — Кавказ
- `articles/coffee.html` — кофе
- `articles/photo.html` — фотография
- `about.html` — об авторе
- `rss.xml` — RSS-лента

---

## Server2 (exit, 203.0.113.30) — что используется

### Xray inbounds (что важно для связки)

- `tunnel-1`..`tunnel-10` на `127.0.0.1:10443-10452` — принимают VLESS от new VPS через SSH-туннель
- UUID для всех 10: `65116ee4-ed08-5880-8d46-b52b8f6b9513`
- Network: TCP, без TLS (внутри SSH-туннеля)
- Routing: freedom → Internet (выход 203.0.113.30)

### SSH

- Порт 56777 (снаружи закрыт; вход только с entry-узлов по ключу)
- `/root/.ssh/authorized_keys` на 2026-06-01 (5 → 4 ключа):
  - `root@srv1` — LLM-сервер (для tg-gemma-bot/llm-forward на Aeza)
  - `tunnel-from-newvps@203.0.113.10` — **рабочий** ключ entry-VPS 104
  - `tunnel@203.0.113.30` — петля на себя (назначение неясно, не трогали)
  - `root@hijac` (RSA) — происхождение неясно, не трогали
  - ~~`root@entry.example.net`~~ — **удалён 2026-06-01** при демонтаже линка Aeza↔Server2 (бэкап `authorized_keys.bak-aeza-*`)

### Демонтаж линка Aeza↔Server2 (2026-06-01)

Связка 178↔194 была мёртвым балластом (через Aeza клиентов 0, xray access.log пуст с февраля). Демонтировано:
- На Aeza: старые 10 `ssh-forward*` и `tunnel-cleanup` удалены. Новый China relay: `in-cn-xhttp` на `:443`, Reality+XHTTP `mode=auto`, пять клиентов (`win178-test`, `iphone178`, `android178`, `wsl178-130`, `win178-149`). Основной Xray передаёт `out-104-relay` локальному `xray-egress-194.service` на `127.0.0.1:11041`, `out-104-130` — `xray-egress-130.service` на `127.0.0.1:11042`, а `out-104-149` — `xray-egress-149.service` на `127.0.0.1:11043`. Watchdog проверяет ветки каждые 10 секунд и перезапускает только неисправную. Это **не** восстановление прямого линка 178→194.
- На Server2: удалён ключ Aeza (выше). Established от 178 → 0; путь через 104 не затронут.

### Server2 — слушающие порты (2026-06-01)

- `:443` openvpn, `:56777` sshd, `:80`+`:8444` nginx, `:8443` xray (in-reality-vision), `:2053` xray (in-cdn-ws), `:5300/udp` dnstt-server (slipstream), `127.0.0.1:10443-10452` tunnel-инбаунды
- Десятки `udp *:<high>` — это исходящие UDP-сокеты самого `xray` (QUIC/DNS клиентов на freedom-выходе), **не сканы и не бэкдор**

### Что НЕ трогаем на Server2

- `openvpn@server` :443 — продолжает работать как было
- `wg-quick@wg0` — inactive (был и так)
- Остальные inbound'ы Xray (in-cdn-ws :2053, in-reality-vision :8443) — это эксперименты CDN, оставлены как backup
- `dnstt-server` :5300 (slipstream ns1.example.com) — оставлен

---

## Cloudflare zone `example.com`

| Запись | Тип | Контент | Proxy |
|--------|-----|---------|-------|
| `vpn.example.com` | A | `203.0.113.10` | **DNS only** (для Reality direct) |
| `blog.example.com` | A | `203.0.113.30` | Proxied (бэкап для CDN-канала) |
| `ns1.example.com` | A | `198.51.100.130` | DNS only (slipstream) |
| `t.example.com` | NS | `ns1.example.com` | — (slipstream) |

**NS-серверы:** `ns1.example.net`, `ns2.example.net`

**Origin Rule:** `(http.host eq "blog.example.com") → Destination Port = 2053` (для CDN-канала на Server2)

---

## Njalla — домен example.com

- Дата expiry: 2027-03-21
- Auto-renew: **NO** (нужно вручную продлевать!)
- API token: `<REDACTED_API_TOKEN>` (в `<LOCAL_DNS_TOKEN_PATH>`)
- NS-серверы: делегированы на CF (`huxley`, `kara`)

---

## Воспроизведение с нуля (disaster recovery)

См. `IMPROVEMENTS.md` §1.1 — Hot-spare VPS на другом хостере. Шаги:
1. Купить VPS у нового хостера, минимум 1vCPU/1GB
2. Сравнить `apt install nginx certbot autossh ufw fail2ban iptables-persistent python3 unzip`
3. Скачать Xray-core: `https://github.com/XTLS/Xray-core/releases/latest`
4. Создать новый поддомен в CF: `news2.example.com` → новый IP (DNS only)
5. Получить LE cert: `certbot certonly --webroot -w /var/www/html -d news2.example.com`
6. Скопировать с current new VPS:
   - `/etc/xray/config.json` (заменить serverNames на news2, dest на 127.0.0.1:8443)
   - `/root/tunnel-cleanup.sh` `/root/xray-watchdog.sh` (без изменений)
   - `/etc/systemd/system/ssh-forward*.service` (без изменений)
   - Блог `/var/www/html/`
   - SSH-ключ `/root/.ssh/tunnel_key` (сгенерировать новый, добавить на Server2)
7. UFW killswitch: повторить набор правил из `AUDIT.md` (выше)
8. Crontab: те же 3 строки
9. Сгенерировать новые reality keys (или скопировать те же)
10. Сгенерировать новые UUIDs или скопировать — клиентские ссылки выпустить заново

---

## Что НЕ задокументировано (намеренно)

- Пароли личных аккаунтов владельца (Cloudzy, Njalla, Cloudflare через браузер)
- Список реальных клиентов, кому какие UUID выданы
- История переписки с провайдерами

Эта инфраструктура — **достаточно** чтобы при потере любого сервера восстановить полностью за 2-3 часа.
