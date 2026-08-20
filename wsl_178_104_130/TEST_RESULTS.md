# Финальные результаты WSL → 178 → 104 → 130

**Дата:** 2026-08-18.
**Статус:** canary был успешно запущен, затем выполнен rollback. Сейчас профиль
не активен; рабочий WSL использует прямой `104 → 130`.

## Главное открытие

Прямой XHTTP+Reality ClientHello Linux/WSL до `178:443` получал Reality fallback,
хотя тот же UUID работал через Windows Xray. Серверная маршрутизация была
исправна.

Рабочим решением стала клиентская фрагментация **только TLS ClientHello** через
Xray `freedom` outbound и `sockopt.dialerProxy`:

```json
{
  "tag": "fragment",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "UseIPv4",
    "fragment": {
      "packets": "tlshello",
      "length": "50-100",
      "interval": "1-3"
    }
  },
  "streamSettings": {
    "sockopt": {
      "interface": "eth0",
      "tcpNoDelay": true
    }
  }
}
```

Основной VLESS outbound содержит:

```json
"sockopt": {
  "dialerProxy": "fragment",
  "tcpKeepAliveIdle": 15,
  "tcpKeepAliveInterval": 10
}
```

Официальная возможность Xray `freedom.fragment`/`dialerProxy`:

- <https://github.com/XTLS/Xray-core/issues/2392>
- <https://github.com/XTLS/Xray-core/blob/main/proxy/freedom/freedom.go>

## Сравнение canary

| Вариант | Результат |
|---|---|
| без fragmentation | Reality fallback |
| fingerprint `chrome` / `firefox` без fragmentation | Reality fallback |
| `tlshello`, length `50-100`, interval `1-3` | **exit 130** |
| `tlshello`, length `10-20`, interval `5` | **exit 130** |
| TCP fragment packets `1-1`, length `1-4` | fallback |
| TCP fragment packets `1-1`, length `4-8` | fallback |

Выбран первый успешный вариант: он даёт меньшую задержку и подтвердил
устойчивость серией тестов.

## Проверка до переключения

- exit IP: 8/8 = `198.51.100.130`;
- YouTube: 3/3 HTTP 200;
- Cloudflare 20 МБ: около `3.3 MB/s`;
- после 30 секунд простоя соединение восстановилось с exit 130.

## Испытанная canary-схема

```text
WSL applications
  → sing-box TUN tun-vless178130
  → Xray SOCKS 127.0.0.1:10810
  → TLS ClientHello fragmentation
  → 203.0.113.20:443, XHTTP/Reality stream-one, user wsl178-130
  → out-104-130
  → 203.0.113.10:443, user relay178-130
  → out-130 (mark 0x82)
  → 198.51.100.130:10443
  → Internet, exit 198.51.100.130
```

## Проверка во время успешного canary

- `/run/vless178130-switch.state`: `SUCCESS`;
- Xray слушает `127.0.0.1:10810`;
- TUN `tun-vless178130` поднят;
- exit `198.51.100.130`;
- YouTube HTTP 200;
- прямой `eth0` заблокирован, curl rc `28`;
- IPv4 OUTPUT разрешает только `203.0.113.20:443`, `lo`, `tun+` и намеренно
  сохранённый `ESTABLISHED,RELATED`;
- IPv6 OUTPUT policy DROP;
- на 104 зафиксировано 66 свежих маршрутов `relay178-130 → out-130`;
- `balancer-leak-check`: pool `10`, leaks `0`;
- Xray 178 и 104 active, production 104→194 не изменён.

## Supervisor и первый сбой rollback

Первый foreground-запуск оборвал управляющую Codex-сессию после применения
killswitch; дочерний `nohup` rollback находился в том же process scope и был
завершён вместе с ней.

Исправление:

- supervisor запускается отдельной job через `atd`;
- preflight нового Xray выполняется до остановки старого TUN;
- ожидаемый timeout прямого `eth0` не вызывает ERR trap;
- настоящая ошибка после commit вызывает полный rollback;
- до commit ошибка удаляет только временные правила, старый профиль продолжает
  работать.

Активный supervisor и документированный пример имеют одинаковый SHA-256.

## Ограничение после полного перезапуска WSL

Процессы автоматически не стартуют. После перезапуска выполнить одну команду:

```bash
sudo /usr/local/bin/start-vless178130
```

Она безопасно использует `atd`; старые имена запуска перенаправлены на неё.

## Итоговое решение владельца

Несмотря на успешный первичный canary, WSL не переводится на 178 постоянно:

- расширенный тест показал отдельные timeout и обрыв длинной загрузки;
- цепочка добавляет ещё один XHTTP hop и ещё одно состояние восстановления;
- после рестарта 178 локальный Xray WSL не всегда переподключался без recovery;
- прямой WSL→104→130 проще, давно используется и после rollback снова даёт
  exit `198.51.100.130` с работающими DNS/YouTube и killswitch;
- замер 3×20 МБ: 31.26/32.61/35.93 Mbit/s, медиана `32.61 Mbit/s`, ошибок 0/3.

Поэтому fragment-профиль остаётся задокументированным кандидатом, а не active
production. Команда `start-vless178130` предназначена только для осознанного
повторного эксперимента.

## Операционное состояние после инцидента 2026-08-19

Результаты выше фиксируют успешное испытание профиля через 178, но не означают,
что он сейчас активен. После общего server-side сбоя выполнен rollback:

- активный WSL: `wsl_130`, транспорт напрямую к 104;
- exit: `198.51.100.130`;
- профиль `wsl_178_104_130` и его supervisor сохранены как кандидат;
- на 178 egress 194 и 130 впоследствии разделены на независимые systemd-сервисы.
