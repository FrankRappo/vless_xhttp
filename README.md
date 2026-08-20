# VPN-канал на новом VPS — VLESS + Reality + XHTTP + связка с Server2 (production)

> [!IMPORTANT]
> This is a **sanitized public reference**. All server addresses, domains, UUIDs,
> Reality keys, short IDs, SSH keys, passwords, and share links are examples.
> Generate unique credentials and review the security model before deployment.


**Дата ввода в эксплуатацию:** 2026-05-22
**Основной вход:** 203.0.113.10; для Китая с 2026-08-18 используется дополнительный entry-hop 203.0.113.20.
**Операционные заметки:** [`OPERATIONS.md`](./OPERATIONS.md) — SSH-доступ, China relay 178, killswitch на 104
**Профили China relay:** [`178_104_194/README.md`](./178_104_194/README.md) — Windows/iPhone/Android
**Windows с exit 149 через China relay:** [`178_104_194/windows-178-104-149.txt`](./178_104_194/windows-178-104-149.txt) — Windows → 178 → 104 → 149; схема в [`wsl_149/README.md`](./wsl_149/README.md)
**Полная фиксация:** [`FULL_SETUP_178_104_194.md`](./FULL_SETUP_178_104_194.md) — серверы, cleanup, проверки и операции
**Будущие улучшения iPhone:** [`178_104_194/IPHONE_IMPROVEMENTS.md`](./178_104_194/IPHONE_IMPROVEMENTS.md) — пока не применены
**WSL-профиль через China relay:** [`wsl_178_104_130/README.md`](./wsl_178_104_130/README.md) — подготовлен, но после инцидента выполнен rollback на рабочий WSL → 104 → 130
**Изоляция egress 178:** [`178_104_194/EGRESS_ISOLATION.md`](./178_104_194/EGRESS_ISOLATION.md) — независимые процессы 194/130/149 и быстрый health-check
**Временный файлообменник:** [`FILE_HOSTING.md`](./FILE_HOSTING.md) — раздача файла клиенту по скрытой ссылке на `vpn.example.com` с авто-сгоранием

---

## Архитектура

```
Клиент (iPhone/Android/desktop, в РФ)
   │  TLS 1.3, SNI=vpn.example.com, XHTTP stream-one, path=/news-api/v2
   ▼
┌──────────────────────────────────────────────────────────┐
│ Entry: VPS Cloudzy / Tornado Datacenter (London, UK)    │
│ IPv4: 203.0.113.10  /  ASN: AS198983 (чистый)         │
│                                                          │
│ :443  Xray (VLESS+Reality+XHTTP stream-one)              │
│       dest = 127.0.0.1:8443 (nginx с LE cert)            │
│       serverNames = ["vpn.example.com"]                   │
│       ├─ Авторизованный клиент → tunnel-balancer         │
│       └─ Чужие/пробы → nginx → реальный блог             │
│                                                          │
│ :80   nginx (LE challenge + HTTP-блог)                   │
│ 127.0.0.1:8443  nginx (HTTPS-блог для Reality dest)      │
│                                                          │
│ 10 systemd autossh services:                             │
│   ssh-forward.service … ssh-forward-10.service           │
│   127.0.0.1:10443..10452 → Server2:10443..10452          │
│   (AES-128-GCM, IPQoS=throughput, ServerAliveInterval=5) │
│                                                          │
│ Outbound: tunnel-1..tunnel-10 (VLESS + Mux к 127.0.0.1)  │
│ Balancer: tunnel-balancer (random)                       │
│ Routing: IPv6 → blackhole, всё → tunnel-balancer         │
└─────────────────────┬────────────────────────────────────┘
                      │ SSH-tunnel ×10 (AES-128-GCM)
                      ▼
┌──────────────────────────────────────────────────────────┐
│ Exit: Server2 (London, UK)                               │
│ IPv4: 203.0.113.30  /  ASN: AS62240 Clouvider          │
│                                                          │
│ Xray inbounds 127.0.0.1:10443..10452 (VLESS no security) │
│ → freedom (UseIPv4) → Internet                           │
└─────────────────────┬────────────────────────────────────┘
                      │
                      ▼
                  Internet (exit IP 203.0.113.30)
```

Для клиентов в Китае перед этой неизменённой production-цепочкой добавлен entry-hop:

```text
Windows/Android -- XHTTP stream-one --┐
iPhone         -- XHTTP packet-up  ---┴→ 203.0.113.20:443
                                      → 203.0.113.10:443
                                      → tunnel-1…10 → 203.0.113.30
```

178 принимает оба клиентских режима (`mode=auto`). Обычные устройства используют
`out-104-relay` → изолированный `xray-egress-194.service` → `relay178-test`
и штатный пул `tunnel-1…10` → 194. Ветка-кандидат WSL использует отдельный
`out-104-130` → `xray-egress-130.service` → `relay178-130` → 130. После
испытаний владелец решил оставить активный WSL на прямом рабочем маршруте
104 → 130; профиль через 178 сохранён только как кандидат.

Отдельный Windows-профиль `win178-149` идёт через изолированную
`out-104-149` → `xray-egress-149.service` → существующий на 104
`exit149-2` → `out-149` и даёт exit `203.0.113.40`. Ссылка и операции:
[`wsl_149/README.md`](./wsl_149/README.md).

**Преимущество связки:**
- **Стабильный exit IP** `203.0.113.30` (как было у клиентов с Aeza)
- Разделение entry/exit — выжигание entry не требует смены exit
- Готовность к pool entry-узлов в будущем

---

## Серверы

### Entry: new VPS (Cloudzy)

| Параметр | Значение |
|----------|----------|
| Провайдер | Cloudzy / Tornado Datacenter |
| Локация | London, UK |
| IPv4 | `203.0.113.10` |
| ASN | AS198983 (чистый, малоизвестный ТСПУ) |
| OS | Ubuntu 24.04 |
| SSH | root / `<REDACTED_PASSWORD>` (порт 22) |
| Ресурсы | 1 vCPU / 1 GB RAM / 25 GB disk |

### China entry relay: Aeza

| Параметр | Значение |
|----------|----------|
| IPv4 | `203.0.113.20` |
| Назначение | Первый hop из Китая + SSH jump к 104 |
| Inbound | VLESS + Reality + XHTTP `mode=auto`, `:443` |
| Main routing outbounds | SOCKS `127.0.0.1:11041` → `xray-egress-194.service`; `11042` → `xray-egress-130.service`; `11043` → `xray-egress-149.service` |
| Старый профиль | Удалён; старый прямой линк 178→194 не восстановлен |

### Exit: Server2 (Clouvider)

| Параметр | Значение |
|----------|----------|
| Провайдер | Clouvider |
| Локация | London, UK |
| IPv4 | `203.0.113.30` |
| ASN | AS62240 Clouvider |
| OS | Ubuntu 24.04 |
| SSH | root / `<REDACTED_PASSWORD>` (порт 56777) |
| Ресурсы | 2 vCPU / 961 MB RAM + 1 GB swap |

### SSH-ключ entry → exit

- На new VPS: `/root/.ssh/tunnel_key` (ed25519)
- На Server2: добавлен в `/root/.ssh/authorized_keys`
- Public key: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY_PUBLIC_KEY_REPLACE_ME tunnel-from-newvps@203.0.113.10`

---

## Домен и cert

| Параметр | Значение |
|----------|----------|
| Домен | `vpn.example.com` (через Njalla → Cloudflare) |
| A-запись | `203.0.113.10` (DNS only, **не** через CDN) |
| Cert | Let's Encrypt, auto-renew через certbot |
| Пути cert | `/etc/letsencrypt/live/vpn.example.com/{fullchain,privkey}.pem` |

---

## Xray конфигурация на new VPS

| Файл | Назначение |
|------|------------|
| `/opt/xray/xray` | Бинарь (Xray 26.3.27) |
| `/etc/xray/config.json` | Главный конфиг |
| `/etc/xray/reality.priv` | Reality x25519 приватный ключ |
| `/etc/xray/reality.pub` | Reality x25519 публичный ключ |
| `/etc/xray/clients_new.txt` | 32 боевых UUIDs клиентов |
| `/etc/xray/short_ids.txt` | 8 shortIds |
| `/var/log/xray-access.log` | Access log |
| `/etc/systemd/system/xray.service` | systemd unit |
| `/etc/systemd/system/ssh-forward[-N].service` | 10 autossh-юнитов |

**Reality:**
- privateKey: `REPLACE_WITH_X25519_PRIVATE_KEY`
- publicKey (для клиентов): `4k6nwJzR1r6XU8SLjDvCtSxDiIZt2gniTCwTbax5fEA`
- serverNames: `["vpn.example.com"]`
- dest: `127.0.0.1:8443`
- 8 shortIds в пуле (распределены по 4 клиента)

**XHTTP:**
- mode: **`auto`** (с 2026-08-13; было `stream-one`) — сервер принимает **и `stream-one`, и `packet-up`**. Режим диктует клиент, поэтому packet-up раздаётся по одной ссылке, а все старые stream-one-ссылки продолжают работать без перевыпуска.
- path: `/news-api/v2`
- **TCP keepalive (добавлено 2026-06-01, ужесточено 2026-06-06):** `streamSettings.sockopt` = `{tcpKeepAliveIdle:15, tcpKeepAliveInterval:10}` — серверный TCP-сокет обнаруживает мёртвого peer быстрее. В конфиге исторически присутствует верхнеуровневое `xhttpSettings.hKeepAlivePeriod:30`, но на него **не полагаемся**: актуальный XHTTP H2 keepalive находится в клиентском `extra.xmux`. Клиентские share-ссылки TCP-sockopt не меняют.

**Tunnel outbounds:**
- tunnel-1..tunnel-10 → VLESS to 127.0.0.1:10443..10452
- UUID для Server2 inbound: `65116ee4-ed08-5880-8d46-b52b8f6b9513` (один на все 10 inbound на Server2)
- Mux: concurrency=2, xudpConcurrency=4, xudpProxyUDP443=allow

**Routing:**
- IPv6 destinations → blackhole (anti-leak)
- All TCP/UDP → tunnel-balancer (random между 10 туннелей)

**Hardening:**
- DNS queryStrategy: `UseIPv4` (только в DNS-секции; `direct/freedom` outbound удалён, нет fallback)
- Sniffing TLS/HTTP/QUIC on inbound
- **Killswitch на 104 — iptables-persistent (НЕ ufw: ufw удалён, конфликтует с netfilter-persistent).** Policy `DROP` на INPUT/OUTPUT/FORWARD, автозагрузка через `netfilter-persistent` (enabled).
  - Allowed IN: 22/80/443/tcp, established, интерфейс `wg130`, `198.51.100.130:51821/udp`
  - Allowed OUT: `lo`, интерфейс `wg130`, `203.0.113.30:56777/tcp` (10 туннелей), `198.51.100.130:51821/udp` (отдельный WG), DNS 53, HTTP 80, HTTPS 443, NTP 123, ICMP
  - Путь client1: `out-130` ставит mark `0x82`; firewall разрешает его только к `198.51.100.130:10443`, затем дропает любой другой destination с этим mark. Текущий Xray client1 не использует `wg130`.
  - Защита от утечек через entry-IP если все туннели упадут
- В Xray убран `direct` outbound — нет fallback на freedom
- fail2ban на :22

**Авто-восстановление (cron):**
- `/root/tunnel-cleanup.sh` — каждые 30 сек (через 2 правила: ровно по минуте + sleep 30):
  - port не слушает → restart `ssh-forward-N.service`
  - Send-Q >100KB (затор) → restart
  - RTT >400ms (стейл TCP) → restart
  - retransmit-rate >25% (плохая связь) → restart
- `/root/xray-watchdog.sh` — каждые 2 мин:
  - процесс мёртв → restart xray
  - :443 не слушает → restart
  - RSS >200MB (memory leak) → restart
  - FD >10000 (FD leak) → restart
- Логи: `journalctl -t tunnel-cleanup -t xray-watchdog`

---

## Клиенты

| Файл | UUID-номер | shortId |
|------|------------|---------|
| `iphone-test.txt` | iphone-test (тест-UUID) | `01010101` |
| `clients/client1.txt`..`client4.txt` | 1-4 | `01010101` |
| `clients/client5.txt`..`client8.txt` | 5-8 | `02020202` |
| `clients/client9.txt`..`client12.txt` | 9-12 | `03030303` |
| `clients/client13.txt`..`client16.txt` | 13-16 | `04040404` |
| `clients/client17.txt`..`client20.txt` | 17-20 | `05050505` |
| `clients/client21.txt`..`client24.txt` | 21-24 | `06060606` |
| `clients/client25.txt`..`client28.txt` | 25-28 | `09090909` |
| `clients/client29.txt`..`client32.txt` | 29-32 | `07070707` |

Отдельные профили с персональным выходом:

| Файл | Пользователь | Маршрут | Exit IP |
|------|--------------|---------|---------|
| `clients/client1.txt` | `client1` | 104 → `out-130` (`mark 0x82`) → `198.51.100.130:10443` | `198.51.100.130` |
| `clients/exit104-direct.txt` | `exit104` | 104 → `direct-104` (один хоп) | `203.0.113.10` |
| `clients/exit149.txt` | `exit149` | 104 → `out-149` → 149:10443 | `203.0.113.40` |
| `clients/exit149-2.txt` | `exit149-2` | 104 → `out-149` → 149:10443 | `203.0.113.40` |

Отдельная ссылка с другим режимом транспорта (добавлена 2026-08-13):

| Файл | Пользователь | Отличие от остальных | shortId | Exit IP |
|------|--------------|----------------------|---------|---------|
| `clients/iphone-packetup.txt` | `iphone-pu` | **`mode=packet-up`** вместо `stream-one` — лечит «вылеты» iPhone при уходе в фон и смене WiFi↔LTE. Маршрут обычный (catch-all → балансер) | `01010101` | `203.0.113.30` |
| `clients/iphone-packetup-2.txt` | `iphone-pu-2` | то же, вторая ссылка на второе устройство (различимы в access-логе) | `02020202` | `203.0.113.30` |

Всего на 104: 40 UUID (прежние 38 + `relay178-test` и `relay178-130` от 178), 8 shortIds.
Ссылки на выход 149 продублированы рядом с конфигами: `wsl_149/exit149.txt`, `wsl_149/exit149-2.txt`.

Три клиентских UUID входа 178 и готовые ссылки находятся отдельно в
[`178_104_194/`](./178_104_194/). Они не увеличивают число пользователей 104:
обычные устройства 178 приходят под `relay178-test`, а WSL — под отдельным
`relay178-130`, который маршрутизируется только в `out-130`.
Ещё один Windows UUID `win178-149` на 178 находится в
[`178_104_194/windows-178-104-149.txt`](./178_104_194/windows-178-104-149.txt); на 104
он использует уже существующего `exit149-2`, поэтому число UUID на 104 не
изменилось.

---

## Совместимость клиентских приложений

| App | Поддержка XHTTP stream-one |
|-----|----------------------------|
| **v2RayTun** (iOS/Android) | ✅ |
| **Streisand** (iOS) | ✅ (подтверждено) |
| **Shadowrocket** (iOS) | ✅ |
| **Foxray** (iOS) | ✅ |
| **v2box** (iOS) | ⚠️ XHTTP stream-one держит на мобиле нестабильно — «вылеты» по простою/смене сети (на Aeza с Vision/TCP такого не было). Смягчено TCP-keepalive на сервере (2026-06-01). Если мало — Streisand/v2RayTun стабильнее. С 2026-08-13 есть packet-up-ссылки (`clients/iphone-packetup.txt`, `clients/iphone-packetup-2.txt`) — импортировать именно в v2RayTun/Streisand/sing-box, не в v2box |
| **NekoBox** (Android) | ✅ |
| **Hiddify** (cross-platform) | ✅ |
| **v2rayN** (Windows) | ✅ |

---

## Уровень защищённости

| Слой | Реализация |
|------|------------|
| TLS 1.3 + Reality | cert от LE для vpn.example.com, без mismatch |
| Маскировка | nginx с реальным блог-контентом (5+ страниц) |
| Транспорт | XHTTP stream-one (выглядит как обычный HTTP-браузинг) |
| Chain entry/exit | new VPS (AS198983) → SSH → Server2 (AS62240) |
| Reality probe protection | Любой нелегитимный TLS → реальный блог |
| Multi-shortId | 8 shortIds — клиенты разделены |
| IPv6 leak prevention | blackhole outbound + UseIPv4 в DNS |
| SSH-tunnel encryption | AES-128-GCM, ServerAliveInterval=5 |

---

## Восстановление доступа

```bash
# SSH к new VPS — ВНИМАНИЕ: прямой SSH из РФ-сети часто ресетится DPI на kex.
# Надёжно заходить джампом через Aeza (203.0.113.20, реквизиты в AUDIT.md):
ssh -o ProxyCommand="ssh -W %h:%p root@203.0.113.20" root@203.0.113.10

# SSH к Server2 (только через new VPS, по ключу; снаружи :56777 закрыт)
ssh root@203.0.113.10 'ssh -i /root/.ssh/tunnel_key -p 56777 root@203.0.113.30 "hostname"'

# Перезапуск Xray на new VPS
systemctl restart xray

# Перезапуск всех SSH-туннелей
systemctl restart ssh-forward.service ssh-forward-{2..10}.service

# Логи
journalctl -u xray -f
tail -f /var/log/xray-access.log

# nginx
systemctl restart nginx

# Cert
certbot certificates
certbot renew --dry-run
```

---

## Что НЕ делалось

- **direct-laptop x2** (личные устройства владельца) — оставлены в старой Aeza-конфигурации
- **тестировщики test1-6@vps2** — старая инфраструктура VPS2 deprecated (см. memory `vpn_infrastructure.md`)

---

## Оперативное управление client1 через Xray API

Инструкция по локальному Xray API на VPS и точечному отключению/включению только `client1` без рестарта Xray: [`API_CLIENT1_CONTROL.md`](./API_CLIENT1_CONTROL.md).

---

## Changelog

### 2026-08-20
- **Добавлен Windows-профиль `Windows → 178 → 104 → 149`.** На 178 он получил отдельный UUID `win178-149`, routing `out-104-149`, SOCKS `127.0.0.1:11043` и `xray-egress-149.service`; на 104 используется уже готовый `exit149-2 → out-149`. Основной Xray 178 обновлён через API без рестарта (PID `21927` не изменился); ветки 194/130 остались активны и дали прежние exit IP. Готовая ссылка: [`178_104_194/windows-178-104-149.txt`](./178_104_194/windows-178-104-149.txt). Работа на целевом Windows подтверждена владельцем в тот же день.

### 2026-08-19
- **На 178 изолированы egress-ветки 194 и 130.** Основной Xray больше не владеет долговременными XHTTP-outbound: он направляет трафик по локальному SOCKS в `xray-egress-194.service` или `xray-egress-130.service`. Каждая ветка перезапускается независимо.
- **Включён быстрый watchdog egress.** Проверка каждые 10 секунд, targeted restart после двух последовательных ошибок, cooldown 30 секунд. Подробности и точная временная шкала инцидента — [`178_104_194/EGRESS_ISOLATION.md`](./178_104_194/EGRESS_ISOLATION.md).
- **WSL оставлен на маршруте `WSL → 104 → 130` по решению владельца.** Новый fragment-профиль через 178 сохранён только как кандидат: короткие canary были успешны, но расширенная проверка выявила нестабильность и дополнительную зависимость от entry 178.

### 2026-08-18
- **Подготовлен и успешно испытан WSL-профиль `WSL → 178 → 104 → 130`.** Linux Reality ClientHello проходил только после клиентской `freedom.fragment` (`packets=tlshello`, `length=50-100`, `interval=1-3`) через `dialerProxy=fragment`. После последующего инцидента выполнен rollback на прежний маршрут WSL → 104 → 130; профиль и supervisor сохранены как кандидат. Полное описание — [`wsl_178_104_130/README.md`](./wsl_178_104_130/README.md).
- Добавлена China-цепочка `устройство → 178 → 104 → tunnel-1…10 → 194` без замены и рестарта действующего инбаунда 104.
- На 104 через API добавлен один обычный клиент `relay178-test`; отдельного правила у него нет, поэтому он проходит через штатный catch-all. По access-логу подтверждено распределение по всем `tunnel-1…10`; `balancer-leak-check`: `pool=ok`, утечки `0`.
- На 178 старый нерабочий Xray-профиль и старые tunnel-компоненты удалены. Новый `:443`: Reality + XHTTP `mode=auto`, маскировка `www.example.org`, outbound до 104 — XHTTP `stream-one`. Старый прямой линк 178→194 не возвращался.
- Добавлены три отдельных профиля [`178_104_194/`](./178_104_194/): Windows и Android используют проверенный `stream-one`, iPhone — специальный `packet-up` для восстановления после фона/смены сети.
- Сквозная проверка всех трёх UUID с Windows: exit `203.0.113.30`, YouTube `HTTP 200`.

### 2026-08-13
- **Инбаунд переведён `mode: stream-one` → `mode: auto`; выдана первая `packet-up`-ссылка (`iphone-pu`).** Причина — iPhone стабильно «выбивает»: `stream-one` держит сессию на одном непрерывном потоке, уход в фон / смена WiFi↔LTE его убивают. `packet-up` дробит upload на короткие POST-запросы (сбой одного = ретрай, а не пересборка сессии). Транспорт не меняется: `type=xhttp`, `security=reality`, порт 443, домен, `path`, `sni`, `pbk`, `sid` — всё прежнее, в ссылке отличается ровно один параметр `mode`.
  - Сервер с `mode: auto` принимает **оба** клиентских режима, поэтому **все 36 старых ссылок работают без перевыпуска** (проверено: `stream-one` через `iphone-test` даёт exit `203.0.113.30` после апплая).
  - Заведён новый обычный клиент `iphone-pu` (`9eff077a-dc91-57f1-abd1-c97129e66cda`, catch-all → балансер → exit 194), ссылка — `clients/iphone-packetup.txt`. Отдельный UUID выбран, чтобы packet-up был отличим в access-логе и ни одна старая ссылка не трогалась.
  - Применено по схеме `PACKET_UP_PLAN.md`: бэкап `config.json.bak-pktup-20260813-043608`, `xray run -test` → `Configuration OK.`, отложенный `systemd-run --on-active=30 --unit=xray-pktup` со self-revert. Рестарт xray прошёл штатно (`pktup-apply: OK`, pid 1011645 → 3518479, ~1 сек обрыва); админ-SSH при этом ожидаемо отвалился и переподключился, живые клиенты (client1, client5, client20, client13, client24, iphone-test) продолжили работать.
  - Проверка вживую с Aeza (внешний клиент, временный xray в `/tmp`, снесён после теста): packet-up с UUID `iphone-pu` → exit `203.0.113.30`, wikipedia 120 КБ за 0.34 с; в access-логе 104 коннекты `iphone-pu` ушли в `tunnel-8`/`tunnel-9`, то есть штатным маршрутом. `balancer-leak-check`: `pool=ok leaks=0`.
  - Правок в `balancer-leak-check.sh` не требуется: `iphone-pu` — обычный клиент, `EXPECT` описывает только персональные выходы.
  - На телефоне использовать **v2RayTun / Streisand / sing-box**, не v2box (у v2box слабый авто-реконнект, он съест половину выигрыша). `xmux` не добавлялся — это следующий шаг, и раздавать его надёжнее JSON-конфигом, т.к. не все мобильные клиенты читают `extra` из share-ссылки.
  - Откат: вернуть телефону старую ссылку (на `auto`-сервере stream-one принимается сразу, серверных правок не нужно).
- **Вторая packet-up-ссылка `iphone-pu-2`** (`f818d831-3ad1-5c72-9409-49a8c0ec58b3`, `clients/iphone-packetup-2.txt`, shortId `02020202`) — для второго устройства, отдельный UUID для различимости в access-логе. Добавлена **через Xray API без рестарта** (`adu`), pid xray не менялся (3518479), живые сессии не рвались; продублирована на диск (`xray run -test` → OK, бэкап `config.json.bak-pu2-20260813-044716`). Клиентов стало 38.
  - ⚠️ **Грабли `xray api adu`:** фрагмент инбаунда должен содержать не только `tag`+`clients`, иначе билд конфига падает ещё до добавления. Первая попытка — `failed to build config: Listen on AnyIP but no Port(s) set`, вторая — `VLESS settings: please add/set "decryption":"none"`. Рабочий минимум: `{"inbounds":[{"tag":"in-reality-xhttp","listen":"0.0.0.0","port":443,"protocol":"vless","settings":{"decryption":"none","clients":[{"id":"…","email":"…"}]}}]}` → `add user … result: ok`.
  - ⚠️ **Aeza как точка теста ненадёжна для замеров скорости.** При проверке второй ссылки wikipedia (120 КБ) с Aeza вставала в таймаут ~8 минут подряд по обеим packet-up-ссылкам, при этом мелкий ответ (ipify, 15 байт) проходил, exit был здоров (curl с самого Server2 — 200 за 0.27 с), все 10 туннелей активны, Send-Q 0, `tunnel-cleanup` молчал. С самого 104 в тот же момент обе packet-up-ссылки и stream-one давали wikipedia за ~0.15 с и 1 МБ за ~0.2 с. Через несколько минут packet-up с Aeza заработал и на клиенте 26.2.6, и на 26.3.27. Вывод: транзиент на аплинке Aeza (её IP выжжен ТСПУ), не свойство ссылки/режима. **Для замеров пропускной способности тестировать с 104, а не с Aeza.**

### 2026-07-24
- **Добавлена вторая персональная цепочка: `exit149` → новый exit-VPS `203.0.113.40` (Vultr, Debian 12).** Полное описание — [`FULL_SETUP_104_149_EXIT149.md`](./FULL_SETUP_104_149_EXIT149.md). Схема повторяет `client1 → out-130 → 130`: WSL → 104:443 (та же Reality/xHTTP маскировка) → outbound `out-149` (mark 149/`0x95`, mux off) → `203.0.113.40:10443` → интернет.
  - На 149: Xray 26.3.27 (официальный installer), inbound `in-from-104` на `0.0.0.0:10443` (VLESS, security none), freedom `UseIPv4`, IPv6 → blackhole; ufw пускает 10443 **только с `203.0.113.10`** (проверено с постороннего хоста — timeout).
  - На 104: outbound `out-149`, пользователи `exit149` и `exit149-2` (два клиента на один выход — для двух устройств, различимы в access-логе), общее routing-правило `exit149-out` с `user: [exit149, exit149-2]` до catch-all балансера, iptables-пара для mark `0x95` (allow только на `203.0.113.40:10443`, остальное DROP) в `/etc/iptables/rules.v4`. Применено **через Xray API без рестарта** (`ado`/`adu`/`adrules`), pid Xray не менялся (1011645), живые сессии 32 клиентов не рвались; продублировано на диск, бэкап `config.json.bak-20260724-221011Z`.
  - Инвариант соблюдён: тег `out-149` вне префикса `tunnel-`, пул балансера остался ровно `tunnel-1..10`.
  - `/root/balancer-leak-check.sh` расширен на четвёртый маршрут (ловит `обычный→149` и `exit149*→194/130/104`); карта выходов вынесена в переменную `EXPECT` в начале скрипта — **нового персонального клиента обязательно дописывать туда**, иначе ложный алерт. Проверено самотестом на подложном логе, 0.03с/запуск, ложных срабатываний нет.
  - В WSL: `wsl_149/xray-exit149-104.json` (SOCKS 10809) + `wsl_149/sing-box-tun-to-149.json` (TUN `tun-vless149`, 172.19.149.1/30). Killswitch WSL не менялся — транспорт тот же `104:443`. Цепочки 130 и 149 взаимоисключающие (обе поднимают TUN с auto_route). **Враппера `start-vless149` на машине нет** — создавался, но по решению владельца удалён; переключение на 149 только вручную (команды в `FULL_SETUP_104_149_EXIT149.md`, раздел 6), штатный враппер остаётся один — `start-vless130`.
  - Проверено: exit IP через SOCKS 10809 = `203.0.113.40`, при этом цепочка 130 по-прежнему даёт `198.51.100.130`; marked-тест на 104 — `149:10443` CONNECTED, `1.1.1.1:443` с mark 149 BLOCKED.

### 2026-06-04
- **Найдена и исправлена утечка exit IP: обычные клиенты случайно выходили на `130` вместо `194`.**
  - **Симптом (как и сообщил владелец):** конфиг, который должен давать exit `203.0.113.30`, периодически показывал `198.51.100.130`. Плавающий, т.к. random.
  - **Причина:** балансировщик `tunnel-balancer` имеет `selector:["tunnel-"]`, а селектор Xray матчит теги аутбаундов **по префиксу** (`strings.HasPrefix`). Добавленный 2026-06-01 outbound `tunnel-130` (персональный путь client1 → wg130 → 130) тоже начинается с `tunnel-` и поэтому подмешивался в пул random-балансера: пул стал **11** аутбаундов (`tunnel-1..10` + `tunnel-130`) вместо 10. Любой ~1/11 коннект обычного клиента (client2..32) случайно уходил через wg130 и светил exit `130`.
  - **Масштаб (по access-логу):** **112 568** соединений утекли на 130; затронуты client2,3,5,10,11,12,13,14,15,20,21,22,23,24,25,26,28,29, iphone-test и др.
  - **Что НЕ затронуто:** `client1` (всегда 130 — у него своё правило `user:client1` ДО catch-all; обратной утечки 130→194 нет — проверено: 0 коннактов client1 в `tunnel-1..10`) и `exit104` (всегда через `direct-104`; тег без префикса `tunnel-`).
  - **Фикс:** outbound переименован **`tunnel-130` → `out-130`** (вне префикса `tunnel-`), routing-правило client1 переведено на `out-130`. Пул балансера снова = ровно `tunnel-1..10`.
  - **Применено вживую через Xray API, БЕЗ рестарта** (`ado out-130` → `adrules client1→out-130` → `rmo tunnel-130`), продублировано на диск `/etc/xray/config.json` (backup `config.json.bak-20260604-183827`). xray pid не менялся (62226), сессии не рвались (кроме самоисцеляющегося блипа админ-SSH на шаге `rmo`). Использован страховочный `systemd-run --on-active` failsafe (снят после проверки).
  - **Проверено после фикса:** 0 строк `tunnel-130` в логе после 18:49:24 UTC; `out-130` использует только client1; обычные клиенты распределены строго по `tunnel-1..10`; `xray -test` диск OK; WSL client1 по-прежнему `198.51.100.130`.
  - ⚠️ **Инвариант на будущее:** селектор балансера — **префиксный**. Любой новый персональный/спец-выход именовать **`out-*` / `exit-*`**, НИКОГДА `tunnel-*`. Пул балансера должен оставаться ровно `tunnel-1..10`.
- **Авто-страж против регрессии этой утечки.** `/root/balancer-leak-check.sh` (вызывается в конце `xray-watchdog.sh`, */2 мин, ~0.06с/запуск): (1) структурный инвариант по конфигу — пул балансера обязан быть ровно `tunnel-1..10`, иначе алерт ещё ДО утечки; (2) поведенческая проверка по `tail -3000` access-лога (не весь файл) — ловит фактические нарушения `обычный→130/104`, `client1→194/104`, `exit104→194/130` (пул сверяется точным множеством, старый self-path не даёт ложных срабатываний). Алерты: `journalctl -t balancer-leak-check`. Бэкап watchdog: `xray-watchdog.sh.bak-*`.
- **Logrotate для access-лога** (`/etc/logrotate.d/xray`): лог рос до 255 МБ без ротации. Теперь `daily`, `rotate 14`, `compress`+`delaycompress`, **`copytruncate`** (xray-core не переоткрывает лог по сигналу → ротация без рестарта, fd остаётся на том же inode), `dateext`, `su root root` (т.к. `/var/log` = `root:syslog 775`). Проверено: первый прогон скопировал 255 МБ в `xray-access.log-20260604`, живой обрезан до 0, xray pid не менялся, запись продолжилась.

### 2026-06-01
- **Демонтирован мёртвый линк Aeza↔Server2.** Aeza (203.0.113.20) больше не туннелирует на exit: на Aeza отключены 10 `ssh-forward*` и убран `tunnel-cleanup` из cron; на Server2 удалён ключ `root@entry.example.net` из `authorized_keys` (бэкап рядом). Рабочий путь через 104 и прочие ключи/сервисы не тронуты. Подробности — `IMPROVEMENTS.md`.
- **Борьба с «вылетами» v2box на телефоне (остаёмся на XHTTP).** Причина — отсутствие keepalive в `stream-one`: при простое телефона NAT оператора рвёт сессию. Добавлен TCP-keepalive на xhttp-инбаунд 104 (см. выше). **Ссылки не менялись.** Если мало — следующий шаг `extra.xmux`+`hKeepAlivePeriod` (проверено `xray -test`).
- **Health-check 104/194:** xray 0 рестартов, туннели не флапают, watchdog'и тихие, Server2 uptime 159д, exit IP `203.0.113.30` корректный.
- **Killswitch на 104 восстановлен (закрыт TODO про ufw).** Выяснилось: `ufw` удалён как пакет (состояние `rc`), а переустановка снесла бы `iptables-persistent`/`netfilter-persistent`. Поэтому killswitch пересобран **на iptables-persistent** (policy DROP + allow-лист, см. «Hardening»), сохранён в `/etc/iptables/rules.v4`+`v6`, грузится автоматически. **Критично:** в allow-лист добавлен путь client1 — интерфейс `wg130` + `198.51.100.130:51821/udp`, без которого рвётся интернет client1 и админ-доступ. Применено вживую без обрыва трафика (атомарный `iptables-restore`, conntrack сохранён) и без рестарта xray. Сквозная проверка: exit client1 = `198.51.100.130`, прямой eth0/IPv6 заблокированы.
- На стороне WSL — отдельный killswitch `/usr/local/bin/killswitch-vless-104` (allow только `eth0→104:443` + `tun+`). Согласован с серверным, правок не требует.

### 2026-06-01 (добавлена конфигурация прямого выхода через 104)
- Заведён клиент **`exit104`** (`clients/exit104-direct.txt`) — один хоп, выход через **сам 104** (`203.0.113.10`), без цепочки на Server2/130.
- На сервере: `freedom`-outbound `direct-104` (`UseIPv4`, `sockopt.mark=104`) + routing `user exit104 → direct-104`. Чтобы killswitch не резал этот выход — правило `iptables OUTPUT -m mark --mark 104 -j ACCEPT` (полноценный туннель, все порты; немаркированные утечки всё равно блокируются).
- Применено **через Xray API (`ado`/`adu`/`adrules`) без рестарта** — живые сессии не оборвались; продублировано на диск + сохранено в `iptables-persistent`.
- Проверено: exit IP `exit104` = `203.0.113.10`, при этом `client1` по-прежнему `198.51.100.130`.
