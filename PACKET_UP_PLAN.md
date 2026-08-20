# Вариант 2 — миграция XHTTP `stream-one` → `packet-up` (резервный план)

**Статус:** ✅ **Шаг A ВЫПОЛНЕН 2026-08-13** — сервер переведён в `mode: auto` (бэкап `config.json.bak-pktup-20260813-043608`, апплай через `systemd-run --unit=xray-pktup` со self-revert, `pktup-apply: OK`).
Шаг B (канарейка) выдан не на `iphone-test`, а на **новые клиенты `iphone-pu`** (`9eff077a-dc91-57f1-abd1-c97129e66cda`, `clients/iphone-packetup.txt`, sid `01010101`) и **`iphone-pu-2`** (`f818d831-3ad1-5c72-9409-49a8c0ec58b3`, `clients/iphone-packetup-2.txt`, sid `02020202`, добавлен через API `adu` **без рестарта**) — чтобы packet-up был отличим в access-логе и ни одна старая ссылка не менялась. Проверено: packet-up → exit `203.0.113.30` (обе ссылки, с 104 и с Aeza), stream-one по-прежнему работает.
⚠️ Замеры скорости делать **с 104, не с Aeza** — у Aeza аплинк под ТСПУ и даёт транзиентные таймауты на объёме (детали — README changelog 2026-08-13). **Шаг C (раскатка на всех) НЕ делался** — решение по итогам наблюдения за iPhone.
**Дата составления:** 2026-06-06. Дополняет `OPERATIONS.md` §2 и `AUDIT.md` (inbound `in-reality-xhttp`).

---

## 0. Когда активировать этот план

Включаем вариант 2, только если **последовательно не помогло**:

1. ✅ **Server TCP keepalive** (сделано 2026-06-06): `tcpKeepAliveIdle:15`/`tcpKeepAliveInterval:10` на инбаунде 104. Поле `hKeepAlivePeriod:30` также присутствует исторически, но клиентский H2 keepalive требует `extra.xmux` на клиенте.
2. ⬜ **Смена приложения на iPhone**: v2box → **v2RayTun / Streisand / sing-box** (та же ссылка, без перевыпуска). Самый дешёвый рычаг — проверить ПЕРВЫМ.

Если после п.1+п.2 iPhone всё равно стабильно «выбивает» при уходе в фон / смене WiFi↔LTE — переходим к packet-up. Это структурное лечение именно этих сценариев.

---

## 1. Главное: packet-up НЕ уводит с XHTTP

`packet-up` — это **режим (`mode`) внутри XHTTP**, не другой транспорт. Решение владельца «остаёмся на XHTTP» соблюдается полностью.

| Что | До (сейчас) | После (вариант 2) |
|-----|-------------|-------------------|
| `type` | `xhttp` | `xhttp` (без изменений) |
| `security` | `reality` | `reality` (без изменений) |
| `mode` | `stream-one` | **`packet-up`** ← единственное смысловое изменение |
| `path`, `sni`, `pbk`, `sid`, порт 443, домен | — | **без изменений** |
| Серверная цепочка (104 → балансер → 10 SSH-туннелей → Server2) | — | **без изменений** |

**Чем packet-up устойчивее на мобиле:** upload дробится на множество отдельных POST-запросов (вместо одного непрерывного потока). Сбойнул один запрос → ретрай; ушёл в фон / сменилась сеть → клиент просто открывает новые запросы, а не пересобирает всю сессию. `stream-one` же держит один двунаправленный поток: умер поток — умерла сессия.

---

## 2. Ключевая идея безопасной миграции: сервер → `mode: auto`

`mode` диктует **клиент**. Сервер с `mode: auto` принимает **И `stream-one`, И `packet-up`** одновременно. Поэтому:

```
Шаг A: сервер stream-one → auto   (один прозрачный серверный апплай, НИЧЕГО не ломает —
                                    старые stream-one-клиенты продолжают работать как есть)
Шаг B: клиентам по одному выдаём packet-up-ссылки   (никаких серверных правок больше не нужно)
```

→ Миграция **инкрементальная, без даунтайма**: можно перевести сначала только `iphone-test`, понаблюдать, потом раскатать на всех. Откат на любом этапе тривиален (старая ссылка stream-one продолжает работать на `auto`-сервере).

---

## 3. Пошаговый план

### Шаг 0 — pre-flight (на 104, джампом через Aeza; см. `OPERATIONS.md` §1)

```bash
BIN=/opt/xray/xray; SRC=/etc/xray/config.json
# текущее состояние режима
jq '.inbounds[0].streamSettings.xhttpSettings' "$SRC"
# фикс-бэкап
cp -a "$SRC" "$SRC.bak-pktup-$(date +%Y%m%d-%H%M%S)"
```

### Шаг A — сервер `stream-one` → `auto` (прозрачно, отложенно, с self-revert)

Та же безопасная схема, что и для keepalive 2026-06-06 (отложенный `systemd-run` +30 сек + само-откат, если xray не поднимется здоровым). Сначала собираем кандидат и ОБЯЗАТЕЛЬНО гоняем `xray run -test` (он ловит неверную схему — именно так был пойман баг с расширением файла при keepalive-апплае).

```bash
BIN=/opt/xray/xray; SRC=/etc/xray/config.json; NEW=/root/config-pktup.json

# 1) кандидат: только mode -> auto (keepalive из 2026-06-06 сохраняется)
jq '.inbounds[0].streamSettings.xhttpSettings.mode="auto"' "$SRC" > "$NEW"

# 2) ВАЛИДАЦИЯ (имя файла обязательно *.json — xray определяет формат по расширению!)
"$BIN" run -test -config "$NEW"     # должно быть "Configuration OK."

# 3) отложенный апплай со self-revert
cat > /root/pktup-apply.sh <<'SH'
#!/bin/bash
SRC=/etc/xray/config.json; NEW=/root/config-pktup.json
BAK=$(ls -t /etc/xray/config.json.bak-pktup-* 2>/dev/null | head -1)
cp -a "$NEW" "$SRC"; systemctl restart xray; sleep 3
if systemctl is-active --quiet xray && ss -tlnp 2>/dev/null | grep -q ':443 '; then
  logger -t pktup-apply "OK: server mode -> auto"
else
  cp -a "$BAK" "$SRC"; systemctl restart xray
  logger -t pktup-apply "FAIL: xray unhealthy -> REVERTED to $BAK"
fi
SH
chmod +x /root/pktup-apply.sh
cp -a "$SRC" "/etc/xray/config.json.bak-pktup-$(date +%Y%m%d-%H%M%S)"
systemctl reset-failed xray-pktup.service 2>/dev/null || true
systemd-run --on-active=30 --unit=xray-pktup /root/pktup-apply.sh

# 4) через ~40 сек проверить
sleep 40
journalctl -t pktup-apply -n 2 --no-pager
jq -c '.inbounds[0].streamSettings.xhttpSettings' "$SRC"   # mode должен быть "auto"
systemctl is-active xray
```

⚠️ Рестарт xray = краткий (~1 сек) обрыв активных сессий, после чего клиенты переподключаются. Моя SSH-сессия идёт на `:22` (не через xray:443) — рестарт её не рвёт; апплай в любом случае server-side и доедет сам.

После шага A **все текущие stream-one-ссылки продолжают работать** — сервер просто стал ещё и принимать packet-up.

### Шаг B — канарейка на `iphone-test` (серверных правок НЕ требует)

Выдать на тестовый iPhone новую ссылку (UUID `iphone-test` = `ced6caea-223b-5a28-8fe1-df14750b2853`), отличие от текущей — только `mode=packet-up`:

```
vless://ced6caea-223b-5a28-8fe1-df14750b2853@203.0.113.10:443?security=reality&sni=vpn.example.com&fp=chrome&pbk=4k6nwJzR1r6XU8SLjDvCtSxDiIZt2gniTCwTbax5fEA&sid=01010101&type=xhttp&path=%2Fnews-api%2Fv2&mode=packet-up&encryption=none#iPhone-packetup
```

Импортировать в **v2RayTun / Streisand / sing-box** (не v2box). Погонять 1–2 дня: фон, блокировка экрана, переключение WiFi↔LTE, метро/лифт. Критерий успеха — нет «выбивает», восстановление после фона мгновенное.

### Шаг C — раскатка на всех клиентов (генератор ссылок)

Если канарейка ок — перевыпустить ссылки всем. Генератор тянет `email → UUID` прямо из боевого конфига (источник истины), сохраняет `email` в `#tag`:

```bash
# на 104:
PBK=$(cat /etc/xray/reality.pub)            # 4k6nwJzR1r6XU8SLjDvCtSxDiIZt2gniTCwTbax5fEA
SID=01010101                                # любой из 8 валидных shortId
jq -r --arg pbk "$PBK" --arg sid "$SID" '
  .inbounds[0].settings.clients[] |
  "vless://\(.id)@203.0.113.10:443?security=reality&sni=vpn.example.com&fp=chrome"
  + "&pbk=\($pbk)&sid=\($sid)&type=xhttp&path=%2Fnews-api%2Fv2&mode=packet-up"
  + "&encryption=none#\(.email)"
' /etc/xray/config.json
```

Сохранить вывод в новые `clients/*.txt` (перезаписать старые stream-one-версии) и разослать. **Старые ссылки при этом не «протухают»** — на `auto`-сервере stream-one тоже принимается, миграция клиентов может растянуться.

> Примечание по спец-клиентам: `client1` (выход → 130) и `exit104` (выход → 104) маршрутизируются на сервере по `email`, формат ссылки у них такой же — packet-up на них применим без изменения маршрутизации.

---

## 4. (Опционально) xmux — переиспользование соединений

Для ещё большей устойчивости/латентности на packet-up добавляют `xmux` (пул H2-соединений с keepalive). Это **клиентская** настройка (`streamSettings.xhttpSettings.extra.xmux`). Серверный inbound XMUX не требует; верхнеуровневое историческое `hKeepAlivePeriod:30` на сервере не заменяет клиентский XMUX.

Надёжнее всего раздавать xmux **JSON-конфигом** (как в `wsl_130/xray-client1-104.json`), т.к. не все мобильные клиенты читают `extra` из share-ссылки. Рекомендованный блок (значения — ориентир, ОБЯЗАТЕЛЬНО прогнать через `xray run -test` под версию 26.3.27 перед раздачей):

```json
"streamSettings": {
  "network": "xhttp",
  "security": "reality",
  "xhttpSettings": {
    "path": "/news-api/v2",
    "mode": "packet-up",
    "extra": {
      "xmux": {
        "maxConcurrency": "16-32",
        "maxConnections": 0,
        "cMaxReuseTimes": 0,
        "hMaxRequestTimes": "600-900",
        "hKeepAlivePeriod": 30
      }
    }
  },
  "realitySettings": {
    "serverName": "vpn.example.com",
    "fingerprint": "chrome",
    "publicKey": "4k6nwJzR1r6XU8SLjDvCtSxDiIZt2gniTCwTbax5fEA",
    "shortId": "01010101"
  }
}
```

Проверка перед раздачей (на любой машине с xray, например на 104 во временный файл):
```bash
/opt/xray/xray run -test -config /root/test-client-pktup.json   # "Configuration OK."
```

Если какое-то поле xmux версия не примет — `-test` это покажет; убрать/переименовать поле (схема xmux менялась между версиями Xray). Без xmux packet-up тоже работает — xmux лишь добавляет переиспользование.

---

## 5. Верификация

- **Функционально:** клиент подключается, трафик идёт, в access-логе 104 у нужного `email` есть свежие `accepted` строки:
  ```bash
  grep -E 'email: iphone-test$' /var/log/xray-access.log | tail -5
  ```
  (⚠️ якорь `$` обязателен — `client1` ловит `client10..19`; см. `OPERATIONS.md` §4.4.)
- **Сам режим (packet-up vs stream-one) в access-логе НЕ виден** — проверять по стабильности на устройстве и по статусу соединения в приложении. packet-up даёт характерный паттерн множества коротких запросов вместо одного долгого.
- **Балансер не поехал:** инвариант пула остаётся (этот план аутбаунды не трогает), но на всякий:
  ```bash
  /root/balancer-leak-check.sh; cat /run/balancer-leak-check.heartbeat
  ```

---

## 6. Откат (многоуровневый)

| Уровень | Ситуация | Действие |
|---------|----------|----------|
| Клиентский | конкретному iPhone packet-up не зашёл | вернуть ему старую `stream-one`-ссылку — на `auto`-сервере работает сразу, без серверных правок |
| Автоматический | xray не поднялся после шага A | self-revert в `pktup-apply.sh` сам вернёт бэкап (`logger -t pktup-apply` покажет `REVERTED`) |
| Ручной серверный | нужно полностью убрать `auto` | `jq '.inbounds[0].streamSettings.xhttpSettings.mode="stream-one"' ... ` → `xray -test` → отложенный апплай той же схемой. **Но обычно не нужно:** `auto` строго пермиссивнее `stream-one`, держать его безопасно |
| Полный | catastrophe | восстановить из `config.json.bak-pktup-*` → `systemctl restart xray` |

---

## 7. Риски и заметки

- **Двойной TCP (XHTTP-over-Reality, затем SSH-туннели 104→Server2) сохраняется** — packet-up его не убирает, но канал 104↔Server2 здоров (retransmit ~0.15%, проверено 2026-06-06), это не узкое место.
- **Боевой конфиг — источник истины для UUID.** Генератор (шаг C) читает из него, не из локальных `.txt` (они могут отстать).
- **shortId:** в ссылках используется `01010101`; валидны все 8 (`01010101,02020202,03030303,04040404,05050505,06060606,09090909,07070707`).
- **Не менять `path`/`sni`/`pbk`** при миграции — иначе сломается Reality-рукопожатие, и проблема будет выглядеть как «packet-up не работает», хотя причина в другом.
- После раскатки обновить `AUDIT.md` (inbound: `mode: auto`, клиенты на packet-up) и `OPERATIONS.md` §2.
