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

## Историческое ограничение canary до 2026-08-28

На этапе canary процессы автоматически не стартовали. Тогда после перезапуска
требовалась одна команда:

```bash
sudo /usr/local/bin/start-vless178130
```

Она безопасно использует `atd`; старые имена запуска перенаправлены на неё.

## Историческое решение после испытаний 2026-08-18/19

После первичного canary WSL тогда не переводился на 178 постоянно:

- расширенный тест показал отдельные timeout и обрыв длинной загрузки;
- цепочка добавляет ещё один XHTTP hop и ещё одно состояние восстановления;
- после рестарта 178 локальный Xray WSL не всегда переподключался без recovery;
- прямой WSL→104→130 проще, давно используется и после rollback снова даёт
  exit `198.51.100.130` с работающими DNS/YouTube и killswitch;
- замер 3×20 МБ: 31.26/32.61/35.93 Mbit/s, медиана `32.61 Mbit/s`, ошибок 0/3.

Поэтому в состоянии на 2026-08-19 fragment-профиль оставался кандидатом, а не
active production. Это историческое решение заменено повторной проверкой и
профильным переключателем, описанными ниже.

## Операционное состояние после инцидента 2026-08-19

Результаты выше фиксируют успешное испытание профиля через 178, но не означают,
что он сейчас активен. После общего server-side сбоя выполнен rollback:

- активный WSL: `wsl_130`, транспорт напрямую к 104;
- exit: `198.51.100.130`;
- профиль `wsl_178_104_130` и его supervisor сохранены как кандидат;
- на 178 egress 194 и 130 впоследствии разделены на независимые systemd-сервисы.

## Повторная проверка 2026-08-28

Клиентский Reality SNI обновлён с архивного `www.rt.ru` на действующий
`www.example.org`. UUID пользователя `wsl178-130`, public key, short ID, XHTTP
path `/ru-feed/api/v3`, режим `stream-one` и TLS ClientHello fragmentation
`50-100` / `1-3` сохранены.

Добавлен постоянный выбор между `104-130` и `178-104-130`. Boot/cron теперь
обслуживают выбранный профиль, а общий lock исключает одновременный switch и
health-recovery. Долгоживущие Xray/sing-box не наследуют lock-дескриптор.

Фактически проверено:

- конфиги Xray и sing-box проходят встроенную валидацию;
- оба killswitch ruleset проходят изолированный namespace-тест;
- switch через 178: `PREFLIGHT_OK`, затем `SUCCESS`;
- exit IP: `198.51.100.130`;
- разрешённый прямой транспорт: только `203.0.113.20:443`;
- IPv4 INPUT/FORWARD/OUTPUT: `DROP`;
- IPv6 INPUT/FORWARD/OUTPUT: `DROP`;
- после остановки `tun-vless178130` default traffic, прямой `eth0` и IPv6
  остались заблокированы;
- recovery после fail-closed теста вернул здоровый профиль;
- три последовательные загрузки по 20 000 000 байт завершились с HTTP 200;
- после 35 секунд простоя full health-check и watchdog показали `HEALTHY`;
- ручной rollback вернул `104-130`, `tun-vless130`, точный allow на
  `203.0.113.10:443` и тот же exit 130.
- после `wsl --shutdown` selector `178-104-130` сохранился и профиль был
  автоматически восстановлен с `SUCCESS`; boot helper синхронно применяет
  killswitch и завершает проверенный запуск VPN до запуска фоновых сервисов.
- ruleset обоих профилей теперь применяется транзакционно через
  `iptables-restore`/`ip6tables-restore`;
- холодный старт отдельно проверен с selector `104-130` и `178-104-130`: уже в
  первой пользовательской команде IPv4/IPv6 OUTPUT были `DROP`, прямой `eth0`
  заблокирован, затем профиль стал `HEALTHY`, exit `198.51.100.130`;
- живой fail-closed тест после транзакционного обновления успешно пройден для
  обоих профилей: default IPv4, прямой `eth0` и IPv6 остались заблокированы.

## SSH через TUN: проверка 2026-08-28

Широкое правило `to 203.0.113.20 lookup main` заменено селективным:

```text
8999: from all to 203.0.113.20 ipproto tcp dport 443 lookup main
```

Отдельный host route `203.0.113.20/32` из main table удалён. Проверено до и
после холодного старта WSL, а также после живого fail-closed/recovery теста:

```text
TCP/443 → dev eth0
TCP/22  → dev tun-vless178130 table 2022
main host route to 178 → absent
exit IP → 198.51.100.130
```

Полный killswitch сохранился: напрямую через `eth0` разрешён только
`203.0.113.20:443`, IPv4/IPv6 OUTPUT имеют policy DROP. Временный локальный
SSH-forward через 104 успешно открыл `127.0.0.1:19022` и вернул banner
`OpenSSH_9.6p1`, что подтверждает работу `ssh -L` через TUN.

Первый вход на `203.0.113.20:22` сбрасывался до SSH banner, хотя kernel route
уже указывал TUN. Причина обнаружена во внутреннем routing sing-box: старое
правило `203.0.113.20/32 → direct` перехватывало весь адрес независимо от
порта. Правило удалено; прямой обход нужен только внешнему сокету Xray и уже
обеспечивается селективным policy rule TCP/443.

После fail-closed/recovery с обновлённым sing-box фактическая парольная SSH-
авторизация прошла успешно:

```text
LOGIN_OK host=entry.example.com
source=198.51.100.130
```

Таким образом SSH/SCP/SFTP и пользовательские `-L`/`-R`/`-D` идут через Xray и
exit 130; реальный IP Windows/WSL на Aeza не виден.
