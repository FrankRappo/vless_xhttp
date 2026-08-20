# Улучшения VPN-инфраструктуры — что сделано и что можно

**Дата:** 2026-05-22
**Архитектура текущая:** см. `README.md`

---

## Сессия 2026-06-01 (диагностика + чистка)

### Жалоба: на телефоне в v2box VPN постоянно «вылетает» (на Aeza такого не было)

**Диагностика серверов (всё здорово):**
- 104: xray active, `NRestarts=0`, все 10 `ssh-forward` живут с ручной перезагрузки владельца, watchdog'и за час не сработали, ошибок в логе нет.
- Server2 (194): uptime 159 дней, xray `NRestarts=0` с 21 мая, exit IP `203.0.113.30` корректный.
- Вывод: серверная цепочка стабильна, обрывы — не серверные.

**Найденная причина — транспорт + отсутствие keepalive:**
- При сверке с Aeza выяснилось: на Aeza боевой инбаунд был **VLESS-Vision-Reality/TCP** (`xtls-rprx-vision`, Reality-фронт на 17 рос-сайтов), а на 104 при переезде сменили на **XHTTP stream-one**. Vision мобильно-стабилен, XHTTP stream-one на iOS/v2box рвётся при простое/смене сети.
- В xhttp-инбаунде 104 не было `extra`/xmux/keepalive вообще.

**Решение владельца:** остаёмся на XHTTP (новее, под CDN), Vision НЕ добавляем.

**Сделано:** добавлен TCP-keepalive на xhttp-инбаунд 104 — `streamSettings.sockopt={tcpKeepAliveIdle:30, tcpKeepAliveInterval:15}`. Сервер держит NAT оператора тёплым. **Клиентские ссылки не менялись** (правка на уровне TCP-сокета). Бэкап `/etc/xray/config.json.bak-keepalive-*`, xray перезапущен чисто.

**Следующие шаги, если обрывы останутся (в рамках XHTTP):**
1. Отдельный **клиентский** JSON с `xhttpSettings.extra.xmux` + `hKeepAlivePeriod` (валидировать на версии core приложения). Обычная share-ссылка не гарантирует перенос `extra`; server-side XMUX эту задачу не решает.
2. A/B-тест: та же ссылка в Streisand. Если там стабильно, а в v2box нет — остаток в самом v2box (iOS убивает фоновое расширение), на сервере не лечится.

### Чистка: демонтаж мёртвого линка Aeza↔Server2

Aeza (178) больше не обслуживала клиентов (access.log пуст с февраля), но 10 её туннелей висели на Server2 впустую. Демонтировано:
- Aeza: 10 `ssh-forward*` `disable --now` + `tunnel-cleanup` убран из cron.
- Server2: удалён ключ `root@entry.example.net` из `authorized_keys`.
- НЕ тронуто: путь через 104, не-VPN сервисы Aeza (tg-gemma-bot, llm-srv1-forward, удалёнка), прочие ключи Server2.

### Killswitch на 104 — пересобран на iptables-persistent
- `ufw` оказался удалён как пакет (`rc`); переустановка снесла бы `iptables-persistent`/`netfilter-persistent` (конфликт). Killswitch собран в `/etc/iptables/rules.v4`+`v6` (policy DROP + allow-лист из AUDIT), грузится `netfilter-persistent` (enabled) → переживает ребут.
- Учтён путь client1: `-o wg130` + `198.51.100.130:51821/udp` — иначе рвётся интернет client1 и админ-доступ (джамп идёт той же цепочкой).
- Применено вживую атомарным `iptables-restore` (без обрыва трафика, без рестарта xray), под страховочным systemd-таймером.
- На стороне WSL — свой killswitch `killswitch-vless-104`. Ручной запуск и общий `ESTABLISHED,RELATED` оставлены намеренно по решению владельца 2026-08-18: WSL может использоваться для других задач до включения VPN, а запуск профиля не обязан уничтожать ранее открытые соединения. Это operational choice, не незакрытый TODO.

### Прямой выход через 104 (exit104)
- Отдельная ссылка `clients/exit104-direct.txt` — один хоп, выход через сам 104 (`203.0.113.10`), без vps2.
- Сервер: `freedom`-outbound `direct-104` (`UseIPv4`, `sockopt.mark=104`) + routing `user exit104 → direct-104`; killswitch пропускает метку правилом `OUTPUT --mark 104 ACCEPT` (все порты; немаркированные утечки всё равно блокируются).
- Добавлено через API (`ado`/`adu`/`adrules`) без рестарта + продублировано на диск. Проверено: exit IP = `203.0.113.10` (curl с Aeza + реальный клиент `192.0.2.37` → `-> direct-104`).
- Грабли: на телефоне сначала был виден 194 — v2box держал старый профиль; помогла **переустановка v2ray**.

### Прочее
- На Server2 десятки `udp *:<high>` = исходящие сокеты xray (норма), не сканы. Скана на :56777 нет.

---

## Что сделано (история работы 21-22 мая)

### 1. Диагностика старой инфраструктуры

Установлено:
- IP Aeza `203.0.113.20` **выжжен ТСПУ** окончательно
- Никакая маскировка (vk.com SNI, swissinfo.ch SNI, XHTTP, разные порты) не пробивает блок
- ТСПУ разрешает TCP-handshake, но дропает ответный TLS-трафик (asymmetric drop)
- Проблема не в протоколе, а в **IP в blacklist ТСПУ**

### 2. Попытка CDN через Cloudflare (Server2 :2053)

Настроено:
- Домен `blog.example.com` (через Njalla → CF, NS делегированы на CF)
- Let's Encrypt cert для blog.example.com
- nginx на Server2 :8444 с реальным блог-контентом
- Xray VLESS+WS+TLS inbound :2053 (proxied через CF)
- CF Origin Rule: `blog.example.com:443` → origin port `2053`
- iptables: :2053 принимает только CF IPs (security)
- IPv6 outbound → blackhole, DNS UseIPv4

Результат:
- Серверная цепочка технически работает (foreign VPS HTTP 200 через CDN)
- 33+ запросов/мин от клиента в логе подтверждают что VPN живой
- **НО:** в Safari/YouTube/TG/IG клиента всё равно белые страницы. Локализовать причину не удалось.

### 3. Попытка Reality+XHTTP packet-up (Server2 :8443)

Настроено и не сработало:
- v2box не открывал коннект вообще (0 SYN-пакетов)
- Streisand коннектится, но Recv-Q растёт без чтения — XHTTP packet-up некорректно совпадает между клиентом и сервером

### 4. Попытка Reality+Vision TCP (Server2 :8443)

Настроено — с foreign VPS timeout. Причина не локализована (возможно dest=blog.example.com:8444 не симулирует достаточно реальный HTTPS для Vision-флоу).

### 5. Авто-восстановление (cron watchdog'и) ✓ (2026-05-22)

Скопированы 1:1 с Aeza:
- `/root/tunnel-cleanup.sh` (каждые 30 сек) — проверяет качество SSH-туннелей (Send-Q, RTT, retransmit-rate), рестартует «больные»
- `/root/xray-watchdog.sh` (каждые 2 мин) — проверяет Xray (процесс, порт, RSS, FD), рестартует при сбоях
- Логи в `journalctl -t tunnel-cleanup -t xray-watchdog`
- Cron установлен root'у на new VPS

### 6. Killswitch на entry VPS ✓ (2026-05-22)

- Убран `direct` outbound из Xray config (только tunnel-1..10 + block-v6 в outbounds)
- UFW OUTGOING default = DENY
- Allowed OUT: только loopback + SSH к Server2:56777 + базовые системные (DNS:53, HTTP:80, HTTPS:443, NTP:123, ICMP)
- Гарантия: если все 10 SSH-туннелей упадут, VPN-трафик **физически не утечёт** через entry-IP (203.0.113.10) — DROP политика ядра блокирует

### 7. Развёртывание нового VPS (production) ✓

- Cloudzy/Tornado Datacenter, **AS198983** (чистый ASN, не Aeza/Clouvider)
- IPv4 `203.0.113.10`, London
- Ubuntu 24.04, 1 vCPU / 1 GB RAM
- Установлены: nginx 1.24, certbot 2.9, Xray 26.3.27 (latest), UFW, fail2ban
- Домен `vpn.example.com` (subdomain в example.com)
- LE cert для vpn.example.com
- 5-страничный блог в `/var/www/html/`: главная, 3 статьи (горы/кофе/фото), about, RSS
- nginx :80 (для LE challenge) + nginx 127.0.0.1:8443 HTTPS (для Reality dest)
- Xray :443 — VLESS+Reality+XHTTP `stream-one`, fallback на 127.0.0.1:8443
- 33 UUID (iPhone-test + 32 client), 8 shortIds, по 4 клиента на shortId
- IPv6 outbound → blackhole, DNS UseIPv4, Sniffing TLS/HTTP/QUIC включён
- UFW: только :22, :80, :443 наружу

Подтверждено работает:
- foreign VPS → новый VPS Reality+XHTTP: HTTP 200 google за 0.36с ✓
- iPhone-клиент через Streisand: всё открывается ✓

### 6. Документация

- `/work/vpn/vpn_cdn/POSTMORTEM.md` — что не сработало с CDN и Vision
- `/work/vpn/vpn_cdn/README.md` — описание CDN-канала (deprecated)
- `/work/vpn/vless_xhttp/README.md` — текущая production-архитектура
- `/work/vpn/vless_xhttp/IMPROVEMENTS.md` — этот документ
- `/work/vpn/vless_xhttp/clients/client{1..32}.txt` — ссылки для рассылки

---

## Что можно улучшить

### Приоритет 1: Critical (рекомендую сделать в течение недели)

#### 1.1 Hot-spare VPS на другом ASN

**Зачем:** AS198983 может быть выжжен ТСПУ как Aeza. Если упадёт сейчас — 32 клиента остаются без VPN на часы пока арендуем новый VPS, настраиваем заново.

**Что сделать:** арендовать ещё один VPS на ДРУГОМ хостере (Hetzner DE, Contabo, BuyVM, PQ.Hosting):
- Поставить ту же стек (nginx + LE + Xray)
- Использовать новый домен или субдомен (`news2.example.com`)
- Скопировать конфиг Xray (тот же набор UUIDs, новый Reality private key)
- Подготовить ссылки заранее (с пометкой "backup")
- При выжигании основного — рассылка backup-ссылок занимает минуты

**Стоимость:** $3-5/мес дополнительно.

#### 1.2 Резервная связка через Server2 (203.0.113.30) как exit

**Зачем:** обсудили в чате. Стабильный exit IP, разделение entry/exit, prep для масштабирования.

**Что сделать:**
- На Server2 добавить inbound `127.0.0.1:10080` (VLESS no-security)
- На new VPS поднять autossh от localhost к Server2:10080
- В Xray new VPS добавить outbound `tunnel-194` (через SSH-туннель)
- Routing: всё → tunnel-194

**Архитектура:**
```
Client → new VPS :443 (Reality entry) → SSH-tunnel → Server2 → Internet (exit 203.0.113.30)
```

**Trade-off:** +5-15ms latency, +1 сервис мониторить. Но **exit IP стабилен** — сервисы (банки, captcha, личные кабинеты) клиентов не сходят с ума при ротации entry.

Решать пользователю — сейчас или потом.

#### 1.3 Расширить блог-контент

**Зачем:** ТСПУ active probing становится умнее, может детектить «синтетический» сайт через ML по структуре контента.

**Что сделать:**
- Добавить ещё 10-15 статей разного объёма (от коротких заметок до длинных)
- Картинки (можно открытые stock-фото) к статьям
- Регулярные обновления (cron, добавляющий новую статью раз в неделю — может быть скрипт генерации lorem-ipsum, но лучше реальные тексты)
- Sitemap.xml, robots.txt
- Возможно — простой комментарий-блок (статичные, не функциональные)
- Favicon

**Стоимость:** 2-4 часа работы один раз.

### Приоритет 2: Important (стоит сделать в течение месяца)

#### 2.1 Мониторинг и алертинг

**Что:** скрипт который раз в 5 минут:
- Проверяет что Xray active, nginx active
- Проверяет :443 TLS handshake снаружи
- Проверяет cert expiry (60 дней до — алёрт)
- Проверяет load average, disk space
- При проблеме — Telegram-уведомление

**Где:** на new VPS + на dev-сервере как watchdog (cron).

**Готовый watchdog:** `/work/vpn/vless_ssh/xray-watchdog.sh` есть пример с Aeza, адаптировать.

#### 2.2 Авто-ротация Reality keys

**Зачем:** Reality private key теоретически может утечь через злоупотребление shortId.

**Что:** скрипт раз в 3-6 месяцев генерирует новые x25519 keys, обновляет конфиг, рассылает новые ссылки клиентам.

**Готовность:** руками, без автоматизации. Просто помечать в календаре.

#### 2.3 Регулярные бэкапы конфига

**Что:** ежедневный `tar -czf` `/etc/xray/`, `/etc/nginx/`, `/etc/letsencrypt/`, `/var/www/html/` в S3-compatible / другой VPS.

**Защита от:** случайной потери, hijack VPS.

#### 2.4 Sub-домены и SNI-разнообразие

**Зачем:** ТСПУ может детектить «много клиентов на одном SNI».

**Что:** создать 3-5 субдоменов CF Wales:
- `vpn.example.com` — текущий
- `blog.example.com` — уже есть (используется для CDN-experiment)
- `dev.example.com`, `app.example.com`, `cdn.example.com` — новые

Распределить 32 клиента по разным SNI. Каждый SNI → отдельный inbound с своим LE cert.

**Реализация:** 1-2 часа, требует доп. cert per домен.

### Приоритет 3: Nice to have (по желанию)

#### 3.1 Логи в централизованное хранилище

`/var/log/xray-access.log` сейчас на VPS. При компрометации VPS — логи теряются.

Stream в loki/grafana или отдельный VPS через rsyslog.

#### 3.2 CDN-канал как параллельный резерв

CDN-инфраструктура на Server2 уже настроена (см. `vpn_cdn/`). Если ТСПУ начнёт массовое выжигание AS198983 — переключиться на CDN-канал быстро.

Сейчас не нужен, но "пусть будет" — стоимость = 0, просто не трогать.

#### 3.3 GeoIP блокировки

Если клиенты только из РФ — заблокировать на Xray inbound подключения с не-RU IP (security: только наши клиенты могут даже попробовать).

`"settings": { "clients": [...], "geoip": {...} }`

Снижает риск компрометации шифров от случайных сканеров.

#### 3.4 Per-client traffic stats

Через email-метки в Xray + access-log analyzer — отчёт «кто сколько трафика прокачал». Полезно если кто-то жалуется «медленно» — посмотреть его статистику.

#### 3.5 Web admin panel

`marzban`, `3x-ui`, `x-ui` — open-source панели для управления Xray. Веб-UI для добавления/удаления клиентов, статистики, exporting ссылок.

**Caveat:** добавляет attack surface (веб-панель = больше способов взлома сервера). Не критично, но рассмотреть.

### Приоритет 4: Long-term (стратегия)

#### 4.1 Multi-region exit pool

Для разных типов трафика — разные exit-узлы:
- UK exit (Server2) — для нейтрального
- DE exit (Hetzner) — для европейского контента
- US exit (BuyVM) — для США
- (Возможно) RU exit — для внутренних РФ-сервисов (если потребуется)

Реализация через routing rules в Xray.

#### 4.2 Переход на Hysteria2 / TUIC / X-ray Mihomo

VLESS+Reality — золотой стандарт сейчас, но через 2-3 года будет «старый». Новые протоколы (Hysteria2, TUIC v5) используют QUIC и могут быть резистентнее.

Текущая инфра не препятствует переходу — Xray поддерживает все.

#### 4.3 PQ-cryptography

Reality x25519 — классический elliptic curve. Через 5-10 лет может быть взломан квантовыми компьютерами. PQ-варианты (ML-KEM) уже доступны в Xray-core.

Не критично сейчас, но запомнить.

---

## Резюме

**Сейчас инфра production-ready и максимально защищена для текущих угроз.** 32 клиента работают, маскировка под реальный блог, чистый ASN, Reality+XHTTP best-in-class.

**Что обязательно — Приоритет 1**: hot-spare VPS, возможно связка с Server2 как exit (по решению).

**Что желательно — Приоритет 2**: мониторинг, расширенный блог-контент.

**Остальное** — на ваше усмотрение, по мере роста.
