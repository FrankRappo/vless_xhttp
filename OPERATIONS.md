# Операционные заметки (доступ, Aeza vs 104, killswitch)

Дата актуализации: 2026-08-18. Дополняет `README.md` / `AUDIT.md`.

---

## 1. SSH-доступ к серверам

| Сервер | Как заходить |
|--------|--------------|
| **Entry 104** `203.0.113.10` | **Прямой SSH из РФ-сети ресетится DPI на kex** (`kex_exchange_identification: Connection reset`). Заходить **джампом через Aeza**. |
| **Exit Server2** `203.0.113.30:56777` | Снаружи `:56777` закрыт. Только через 104 по ключу `/root/.ssh/tunnel_key`. |
| **Server 130** `198.51.100.130` | Только для цепочки client1/WSL. К остальным клиентам отношения не имеет. |

Реквизиты (пароли/ключи) — в `AUDIT.md` («Серверы и доступы»).

**Джамп на 104 через Aeza** (два пароля, два независимых sshpass):
```bash
sshpass -e ssh \
  -o ProxyCommand="sshpass -p '<пароль_Aeza>' ssh -W %h:%p root@203.0.113.20" \
  root@203.0.113.10          # SSHPASS=<пароль_104>
```

**На Server2 — джампом через 104 по ключу:**
```bash
ssh root@203.0.113.10 'ssh -i /root/.ssh/tunnel_key -p 56777 root@203.0.113.30 "hostname"'
```

---

## 2. Aeza (203.0.113.20) vs 104 — что есть что

С 2026-08-18 Aeza используется как **China entry relay** и как jump-хост к 104:
- клиент из Китая подключается к `203.0.113.20:443` по Reality+XHTTP;
- 178 передаёт трафик на штатный XHTTP-инбаунд `203.0.113.10:443`;
- на 104 пользователь `relay178-test` идёт через обычный catch-all → `tunnel-balancer` → exit 194;
- отдельный WSL-профиль `wsl178-130 → out-104-130 → relay178-130 → out-130` подготовлен, но сейчас WSL находится на rollback-маршруте напрямую через 104 → 130;
- Windows-профиль `win178-149 → out-104-149 → exit149-2 → out-149` идёт только на exit `203.0.113.40`; ссылка `178_104_194/windows-178-104-149.txt` подтверждена на реальном Windows 2026-08-20, инструкция — `wsl_149/README.md`;
- готовые ссылки и режимы устройств: `178_104_194/README.md`.

На Aeza также остаются независимые сервисы `tg-gemma-bot`, `llm-srv1-forward`,
anydesk/x11vnc/rudesktop. Сервер гасить нельзя.

**Разница клиентских режимов (важно для жалоб на обрывы):**
- Windows/Android → 178: XHTTP `stream-one`, как основной стабильный набор 104;
- iPhone → 178: XHTTP `packet-up`, как специальные iPhone-профили 104;
- inbound 178 и inbound 104 работают в `mode:auto`;
- серверный участок 178→104 использует `stream-one`, а 104→194 остаётся прежним пулом из 10 SSH-туннелей.
- **С 2026-08-13 инбаунд 104 в `mode: auto`** — принимает и `stream-one`, и `packet-up`. Жалоба «на iPhone постоянно падает» лечится выдачей packet-up-ссылки: `clients/iphone-packetup.txt` (клиент `iphone-pu`) и `clients/iphone-packetup-2.txt` (`iphone-pu-2`, второе устройство); старые ссылки при этом ничего не теряют и перевыпуска не требуют. Новые packet-up-клиенты добавляются через Xray API `adu` **без рестарта** (рабочий формат фрагмента — README changelog 2026-08-13). Ниже — история вопроса.
- XHTTP stream-one на мобиле (особенно **v2box**) нестабилен — «вылеты» по простою/смене сети. На инбаунде 104 действует TCP keepalive (`sockopt.tcpKeepAliveIdle=15`, `tcpKeepAliveInterval=10`). Верхнеуровневое `xhttpSettings.hKeepAlivePeriod=30` исторически осталось в конфиге, но не считается клиентским H2 keepalive: актуальный механизм находится в `extra.xmux` клиента. TCP keepalive ускоряет обнаружение мёртвого peer, однако **структурно `stream-one` всё равно рвётся при уходе в фон/смене WiFi↔LTE** — для этого выдаются `packet-up`-профили. Без полного JSON самый надёжный рычаг: сменить клиент **v2box → Streisand / v2RayTun / sing-box**. Решение владельца: **остаёмся на XHTTP**.


**Изоляция egress на 178 (с 2026-08-19):** основной `xray.service` обслуживает
inbound/routing, а реальные XHTTP-outbound вынесены в
`xray-egress-194.service` (SOCKS `127.0.0.1:11041`) и
`xray-egress-130.service` (SOCKS `127.0.0.1:11042`), а Windows-ветка 149 — в
`xray-egress-149.service` (SOCKS `127.0.0.1:11043`). Timer
`xray-egress-health.timer` проверяет их каждые 10 секунд и после двух
последовательных ошибок перезапускает только повреждённую ветку. Для проблемы
iPhone/Windows/Android использовать `systemctl restart xray-egress-194`, а не
общий `xray`. Подробности: `178_104_194/EGRESS_ISOLATION.md`.
Если неисправен только Windows-профиль с exit 149, перезапускать
`xray-egress-149.service`, не основной `xray` и не ветки 194/130.

**Старый прямой линк Aeza↔Server2 остаётся демонтированным.** Новый путь принципиально другой: 178→104 по XHTTP, затем существующий рабочий 104→194. На 178 нет старых `ssh-forward*` и `tunnel-cleanup`; ключ Aeza на Server2 не восстанавливался.

---

## 3. Killswitch на 104

**Механизм: `iptables-persistent`, НЕ ufw.** `ufw` удалён как пакет (состояние `rc`); его переустановка снесла бы `iptables-persistent`+`netfilter-persistent` (конфликт) — **ufw не ставить.** Правила в `/etc/iptables/rules.v4`+`v6`, грузятся `netfilter-persistent` (enabled) при каждом старте.

**Политика:** `DROP` на INPUT / OUTPUT / FORWARD.

**Allow-лист OUT** (два легитимных выхода + системное):
- `lo`, established/related, ICMP
- `203.0.113.30:56777/tcp` — 10 SSH-туннелей (обычные клиенты → exit 194)
- интерфейс `wg130` + `198.51.100.130:51821/udp` — **путь client1** (→ exit 130)
- `mark 104` (`OUTPUT -m mark --mark 104 -j ACCEPT`) — **прямой выход exit104** через сам 104 (freedom-outbound `direct-104` с `sockopt.mark=104`); все порты, немаркированные утечки всё равно блокируются
- DNS 53, HTTP 80, HTTPS 443, NTP 123

**Allow-лист IN:** lo, established, `wg130`, `198.51.100.130:51821/udp`, 22/80/443, ICMP.

⚠️ **Путь client1 (`wg130` + `130:51821`) обязателен** — без него рвётся интернет client1 И админ-SSH (джамп WSL→Aeza→104 сам идёт VPN-цепочкой client1).

**Переживает ребут 104:** `netfilter-persistent`, `wg-quick@wg130`, `xray`, `ssh-forward*` — все `enabled`. Дедлока на старте нет (killswitch пропускает WG-хендшейк, loopback, 56777).

**Как править killswitch безопасно (без обрыва трафика, без рестарта xray):**
1. бэкап: `iptables-save > /tmp/pre.v4; ip6tables-save > /tmp/pre.v6`;
2. страховка: `systemd-run --on-active=300 --unit=ipt-failsafe /bin/bash -c 'iptables-restore</tmp/pre.v4; ip6tables-restore</tmp/pre.v6'`;
3. собрать новый ruleset, `iptables-restore --test`, затем `iptables-restore` (атомарно, conntrack не сбрасывается);
4. проверить доступ → `netfilter-persistent save` → снять страховку (`systemctl stop ipt-failsafe.timer`).

**Текущее состояние WSL:** активны `/usr/local/bin/killswitch-vless-104`, профиль `wsl_130` и маршрут WSL → 104 → 130. Автозапуск закреплён в `/etc/wsl.conf` через detached-wrapper `/usr/local/sbin/start-vless130-at-boot`; журнал `/var/log/vless130-boot.log`, а `/etc/cron.d/vless130-health` повторяет проверку раз в минуту. Это окончательно выбранный владельцем рабочий вариант. Профиль через 178 сохранён как экспериментальный кандидат вместе с `/usr/local/bin/killswitch-vless-178` (allow `eth0` только к `203.0.113.20:443`, IPv6 DROP); этот killswitch **сейчас не активен**. Команда `sudo /usr/local/bin/start-vless178130` не является штатным запуском и используется только для осознанного повторного canary через независимый `atd`.

---

## 4. Маршрутизация выходов, инвариант балансера и диагностика exit-IP

Добавлено 2026-06-04 после инцидента: обычные клиенты случайно выходили на `130` вместо `194`. Причина и фикс — README changelog 2026-06-04.

### 4.1 Карта выходов (источник истины)

| Класс клиента | inbound `user` | outbound | путь | Exit IP |
|---|---|---|---|---|
| Обычные (`client2..32`, `iphone-test`) | — (catch-all) | `tunnel-balancer` random → `tunnel-1..10` | 10 SSH-туннелей → Server2 | **203.0.113.30** |
| `client1` (WSL/телефон) | `user: client1` | `out-130` | VLESS TCP с mark `0x82` → `198.51.100.130:10443` | **198.51.100.130** |
| `exit104` | `user: exit104` | `direct-104` | freedom (`mark 104`) | **203.0.113.10** |
| `exit149`, `exit149-2` (добавлены 2026-07-24) | `user: exit149, exit149-2` | `out-149` | vless tcp (`mark 149`) → 149:10443 | **203.0.113.40** |

Правила routing идут по порядку, первое совпадение выигрывает: правила `client1`, `exit104` и `exit149` стоят **ДО** catch-all, поэтому в балансер не попадают. Обратной утечки (130/104/149 → 194) нет by design.

### 4.2 Инвариант балансера (критично для всех будущих правок)

`tunnel-balancer.selector = ["tunnel-"]` матчит outbound-теги **по префиксу** (`HasPrefix`):
- **Пул балансера = ВСЕ outbound'ы с тегом `tunnel-*`** и обязан быть ровно `tunnel-1..10`.
- **Любой персональный/спец-выход именовать `out-*` / `exit-*`, НИКОГДА `tunnel-*`** — иначе он подмешается в random-пул и обычные клиенты начнут случайно выходить через него (так и был баг `tunnel-130`).
- Селектор нельзя сделать «точечным» (он префиксный) — защита именно в **именовании** аутбаундов.

### 4.3 Авто-страж (regression guard)

`/root/balancer-leak-check.sh` (вызов из `xray-watchdog.sh`, */2 мин, ~0.03с): инвариант пула по конфигу + фактические утечки по `tail` лога. Карта «кто в какой выход» задана переменной `EXPECT` в начале скрипта — **при заведении нового персонального клиента дописать его туда**, иначе он считается обычным и даст ложный `EXIT-IP LEAK`. Алерты:
```bash
journalctl -t balancer-leak-check --since today   # пусто = всё ок
journalctl -t balancer-leak-check -f              # вживую
```
`CONFIG INVARIANT VIOLATED` → в пуле лишний/пропавший `tunnel-*`. `EXIT-IP LEAK` → реальные нарушения в свежем логе с примерами кто→куда.

---

## 5. Тестирование туннелей — на отдельном VPS

Добавлено 2026-07-24.

**Правило: туннели тестируются на отдельном VPS, а не на рабочей машине владельца.**
Рабочая WSL — не стенд: она постоянно ходит в интернет через активную цепочку, и любой
запуск враппера/подъём тестового TUN гасит соседнюю цепочку и рвёт живые соединения.

- Тестовый хост — любой посторонний VPS. Aeza `203.0.113.20` теперь является рабочим China relay, поэтому она не независима для теста полной цепочки через 178; её допустимо использовать только для точечных проверок downstream 104/130, не меняя production Xray.
- На тестовом VPS TUN не нужен: достаточно клиентского конфига Xray с локальным SOCKS и `curl --socks5-hostname` — так проверяется вся цепочка `клиент → 104 → exit` и фактический exit IP.
- Для exit 149 inbound `10443` закрыт для всех, кроме 104. **Исключение — exit 130:** по решению владельца от 2026-08-18 `198.51.100.130:10443` намеренно публично доступен для возможных других задач; защита там — VLESS UUID, а не source-IP firewall.
- На рабочей WSL допустима только параллельная проверка на отдельном SOCKS-порту (10808 занят цепочкой 130, 10809 — цепочкой 149), **без переключения TUN**. Переключать канал — только когда это осознанно нужно владельцу.
- `pkill -f '<шаблон>'` осторожно: шаблон попадает и в собственную командную строку bash — можно убить свою же сессию.

Подробные команды — `FULL_SETUP_104_149_EXIT149.md` §8.

**Жив ли сам страж** (он молчит, когда всё ок → для liveness есть heartbeat, ~73 байта в tmpfs `/run`, перезаписывается каждый запуск):
```bash
cat /run/balancer-leak-check.heartbeat
# last_run=2026-06-04T19:27:44Z pool=ok leaks=normal:0,client1:0,exit104:0
```
Свежий `last_run` (≤2 мин назад) + `pool=ok` + все `leaks:0` = страж работает И нарушений нет. Если `last_run` устарел (> неск. минут) — не отрабатывает `xray-watchdog`/cron. Файл волатильный: после ребута появится заново в течение 2 мин.

### 4.4 Runbook: «клиент показывает не тот exit IP»

SSH на 104 джампом через Aeza (см. §1). ⚠️ **`email: client1` подстрокой ловит и `client10..19` — ВСЕГДА якорить `$`.**

```bash
LOG=/var/log/xray-access.log

# 1. Куда реально ходит конкретный клиент (точное имя, с якорем):
grep -E 'email: client7$' "$LOG" | grep -oE '\-> [a-z0-9-]+\]' | sort | uniq -c | sort -rn
#    обычный клиент должен быть ТОЛЬКО tunnel-1..10

# 2. Матрица класс→outbound за окно после времени T (подставь дату/время):
awk '$1=="2026/06/04" && $2>="HH:MM:SS" && /email: / {
  if(match($0,/-> [a-z0-9-]+\]/)) t=substr($0,RSTART+3,RLENGTH-4); e=$NF;
  cls=(e=="client1")?"client1(130)":(e=="exit104")?"exit104(104)":"normal(194)";
  c[cls" "t]++} END{for(k in c) printf "%9d  %s\n",c[k],k}' "$LOG" | sort

# 3. Прогнать страж и посмотреть счётчики нарушений (все должны быть 0):
/root/balancer-leak-check.sh; journalctl -t balancer-leak-check --since '-1 min' -o cat
```

Если причина в конфиге — проверить пул и правила:
```bash
jq -r '[.outbounds[].tag|select(startswith("tunnel-"))]|sort|join(" ")' /etc/xray/config.json  # = ровно tunnel-1..10
jq -c '.routing.rules[]?' /etc/xray/config.json
```

### 4.5 Logrotate access-лога

`/etc/logrotate.d/xray`: `copytruncate` (без рестарта xray), `daily`/`rotate 14`/`compress`/`delaycompress`/`dateext`/`su root root` (т.к. `/var/log`=`root:syslog 775`). Ручная ротация: `logrotate -f /etc/logrotate.d/xray`. Лог-аналитика (`tail`, runbook выше) переживает ротацию.
