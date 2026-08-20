# Xray API и точечное отключение `client1`

Дата актуализации: 2026-06-04 (outbound client1 переименован `out-130` → `out-130`, см. README changelog 2026-06-04).

Цель: управлять только клиентом `client1` на entry VPS `203.0.113.10`, не отключая остальные VLESS/XHTTP-конфиги.

## Важные правила безопасности

- Не останавливать весь VPS.
- Не выключать `ufw`, watchdog-и, `ssh-forward-*` и Server2.
- Не использовать `xray api adrules -append` для блокировки `client1`: append добавит правило в конец, а существующее правило `client1 -> out-130` сработает раньше.
- API должен слушать только localhost: `127.0.0.1:10085`. Наружу порт API не открывать.
- Перед изменением дискового конфига всегда делать backup и `xray run -test`.
- ⚠️ **Админ-SSH (джамп WSL→Aeza→104) сам идёт по VPN-цепочке `client1`.** Любая live-операция через API, затрагивающая outbound `client1` (`rmo`/переименование), оборвёт твою же SSH-сессию в момент удаления старого outbound. Поэтому такие правки выполнять **отделённым скриптом на самом 104** (`setsid`, пишет результат в файл — переживает обрыв SSH) + страховочный `systemd-run --on-active=300 ... 'cp <fixed-config> /etc/xray/config.json && systemctl restart xray'`, который снимаешь после проверки доступа.
- **Порядок при live-переименовании outbound** (чтобы не разорвать client1/админ-доступ): `ado <new>` → `adrules client1→<new>` → `rmo <old>`. Новый outbound должен существовать ДО перевода правила и ДО удаления старого. Рабочий пример (rename `tunnel-130`→`out-130`, без рестарта) — README changelog 2026-06-04.

## Текущий статус

На 2026-05-26 API уже включён на new VPS.

Проверка:

```bash
ssh root@203.0.113.10

systemctl is-active xray
ss -ltnp | grep -E '127\.0\.0\.1:10085|:443'
jq '.api' /etc/xray/config.json
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

Ожидаемо:

- `xray` active.
- `:443` слушает публично.
- `127.0.0.1:10085` слушает только локально.
- `client1` в дисковом конфиге остаётся на месте.

Backup перед включением API:

```text
/etc/xray/config.json.bak-api-20260526-184246
```

## Как включить API с нуля

Это нужно делать только если API отсутствует в `/etc/xray/config.json`.
Первое включение API требует одного `systemctl restart xray`.

```bash
ssh root@203.0.113.10

CONFIG=/etc/xray/config.json
BACKUP=/etc/xray/config.json.bak-api-$(date -u +%Y%m%d-%H%M%S)
TMP=$(mktemp /tmp/xray-api-enable.XXXXXX.json)

cp -a "$CONFIG" "$BACKUP"

jq '.api = {
  "tag": "api",
  "listen": "127.0.0.1:10085",
  "services": ["HandlerService", "RoutingService", "StatsService"]
}' "$CONFIG" > "$TMP"

/opt/xray/xray run -test -c "$TMP"
install -m 0644 "$TMP" "$CONFIG"
rm -f "$TMP"

systemctl restart xray
sleep 2

systemctl is-active xray
ss -ltnp | grep -E '127\.0\.0\.1:10085|:443'
/opt/xray/xray run -test -c /etc/xray/config.json
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

## Как проверить, что `client1` существует один раз

```bash
jq '[.inbounds[]?.settings.clients[]? |
  select(.id=="e04cf682-507f-55ba-89c9-45446c2d3e6a" or .email=="client1")
] | length' /etc/xray/config.json
```

Ожидаемо: `1`.

## Текущая логика маршрутизации

Сейчас `client1` отделён от остальных отдельным routing-правилом:

```bash
jq '.routing' /etc/xray/config.json
```

Ключевая часть:

```json
{
  "type": "field",
  "inboundTag": ["in-reality-xhttp"],
  "user": ["client1"],
  "outboundTag": "out-130"
}
```

Остальные клиенты идут через `tunnel-balancer`.

## Отключить только `client1` без рестарта Xray

Способ: заменить runtime routing через API так, чтобы правило `user: client1` отправляло трафик в blackhole `block-v6`.

Важно: это меняет runtime-состояние Xray через API. Дисковый `/etc/xray/config.json` не меняется, поэтому после рестарта Xray `client1` снова будет включён по дисковому конфигу.

```bash
ssh root@203.0.113.10

# 1. Сгенерировать runtime routing, где только client1 идёт в block-v6.
jq '.routing.rules |= map(
  if ((.user // []) | index("client1"))
  then .outboundTag = "block-v6"
  else .
  end
) | {routing}' /etc/xray/config.json > /tmp/xray-routing-client1-off.json

# 2. Применить routing без -append, чтобы заменить текущий runtime routing целиком.
/opt/xray/xray api adrules \
  --server=127.0.0.1:10085 \
  /tmp/xray-routing-client1-off.json

# 3. Проверить runtime rules.
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

Ожидаемый результат: правило `client1` теперь ведёт в `block-v6`, остальные правила сохранены.

## Включить `client1` обратно без рестарта Xray

Способ: вернуть runtime routing из дискового конфига, где `client1 -> out-130`.

```bash
ssh root@203.0.113.10

# 1. Взять штатный routing с диска.
jq '{routing: .routing}' /etc/xray/config.json > /tmp/xray-routing-client1-on.json

# 2. Заменить runtime routing целиком.
/opt/xray/xray api adrules \
  --server=127.0.0.1:10085 \
  /tmp/xray-routing-client1-on.json

# 3. Проверить runtime rules.
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

## Проверка после включения/отключения

На VPS:

```bash
systemctl is-active xray
ss -ltnp | grep -E '127\.0\.0\.1:10085|:443'
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

В WSL-клиенте `wsl_130` для `client1`:

```bash
cd /work/vpn/vless_xhttp/wsl_130
curl -4 --max-time 15 -sS https://api.ipify.org ; echo
```

Ожидания:

- Когда `client1` выключен через `block-v6`, WSL-клиент должен не получить нормальный egress.
- Когда `client1` включён обратно, WSL-клиент снова должен показывать exit IP `198.51.100.130`.

## Emergency rollback

Если API routing запутался, самый простой rollback — рестарт Xray: runtime routing снова загрузится из `/etc/xray/config.json`.

```bash
systemctl restart xray
sleep 2
systemctl is-active xray
/opt/xray/xray api lsrules --server=127.0.0.1:10085
```

Это кратко сбросит текущие соединения, но вернёт штатный routing с диска.
