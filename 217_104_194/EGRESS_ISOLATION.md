# Изоляция egress на 178 и инцидент 2026-08-19

## Что произошло

Одновременно перестали передавать трафик iPhone и Windows, использующие
`out-104-relay` и exit `203.0.113.30`. Пользователи, UUID и routing на 178
оставались корректными. Отдельная WSL-ветка `out-104-130` имела другую сессию.

Подтверждённая эксплуатационная причина — общий процесс Xray на 178 одновременно
владел публичным inbound и обеими долговременными XHTTP-сессиями к 104. Зависший
egress нельзя было безопасно перезапустить отдельно: точечная API-замена outbound
не закрывала все старые потоки, а рестарт общего Xray рвал также WSL. Внутренняя
причина зависания XHTTP/XMUX на уровне Xray не доказана, поэтому она не
фиксируется как подтверждённый upstream bug.

## Постоянная схема

Основной `xray.service` на 178 теперь отвечает за inbound, пользователей и
routing. Его логические outbounds — локальные SOCKS:

- `out-104-relay -> 127.0.0.1:11041`;
- `out-104-130 -> 127.0.0.1:11042`;
- `out-104-149 -> 127.0.0.1:11043`.

Реальные VLESS/Reality/XHTTP-сессии вынесены в независимые процессы:

| Ветка | Unit | Локальный вход | Пользователь на 104 | Exit |
|---|---|---:|---|---|
| устройства | `xray-egress-194.service` | `127.0.0.1:11041` | `relay178-test` | `203.0.113.30` |
| WSL-кандидат | `xray-egress-130.service` | `127.0.0.1:11042` | `relay178-130` | `198.51.100.130` |
| Windows exit 149 | `xray-egress-149.service` | `127.0.0.1:11043` | `exit149-2` | `203.0.113.40` |

Все unit имеют `Restart=always`. Перезапуск одной ветки не меняет PID основного
Xray и не затрагивает остальные ветки.

## Автовосстановление

`xray-egress-health.timer` запускает `/usr/local/sbin/xray-egress-health`
каждые 10 секунд. Для каждой ветки отдельно выполняется HTTPS-проверка через её
SOCKS с таймаутом 5 секунд.

- один сбой только увеличивает счётчик;
- два последовательных сбоя запускают targeted restart только соответствующего
  `xray-egress-*.service`;
- cooldown 30 секунд предотвращает цикл рестартов;
- состояние: `/run/xray-egress-health.state`;
- журнал: `journalctl -u xray-egress-health.service`.

Обычное окно обнаружения активного зависания — около 20–25 секунд вместо прежних
60–90 секунд. После серверного восстановления клиент iPhone может показать
интернет позже, если приложение держит старую сессию в фоне: сервер не может
заставить iOS немедленно отправить новый запрос.

## Время восстановления 2026-08-19

По journal ветки 194:

- 03:16:38 MSK — targeted restart `xray-egress-194.service`;
- 03:16:40 — контрольный HTTPS прошёл;
- 03:16:41 — первый трафик Apple Push;
- 03:17:18 — трафик iCloud;
- 03:21:00 — интерактивный трафик Instagram;
- основной `xray.service` и ветка 130 не перезапускались.

Таким образом, серверная ветка восстановилась за 2–3 секунды. Разница до
визуального восстановления на телефоне была временем переподключения/активации
клиента iOS, а не продолжением серверного простоя.

## Сохранённые образцы

- `xray-egress-health.example.sh`;
- `xray-egress-health.service.example`;
- `xray-egress-health.timer.example`.

Образцы скопированы с активного сервера после ускорения watchdog.

## Операции

Проверка:

```bash
systemctl is-active xray xray-egress-194 xray-egress-130 xray-egress-149 xray-egress-health.timer
/usr/local/sbin/xray-egress-health
cat /run/xray-egress-health.state
```

Если автоматике не удалось восстановить только iPhone/Windows/Android:

```bash
systemctl restart xray-egress-194.service
```

Если неисправна только ветка WSL-кандидата:

```bash
systemctl restart xray-egress-130.service
```

Если неисправен только Windows-профиль с exit 149:

```bash
systemctl restart xray-egress-149.service
```

Не перезапускать общий `xray.service` для одиночной egress-проблемы: это
ненужно разрывает все входящие клиентские сессии.

## Надёжность основного inbound после перезагрузки

19 августа 2026 после перезагрузки основной `xray.service` не смог прочитать
`/usr/local/etc/xray/config.json`: unit запускается как `nobody`, а файл после
предыдущей атомарной замены остался `root:root 0600`. Уже загруженный до
перезагрузки процесс скрывал ошибку; новый старт завершался с кодом 23. Обе
изолированные egress-ветки при этом оставались исправны, поэтому их watchdog не
обнаруживал мёртвый публичный inbound `:443`.

Постоянная защита:

- config: `root:nogroup 0640`;
- unit явно использует `Group=nogroup`, `Restart=always`, `RestartSec=2s`;
- `/etc/systemd/system/xray.service.d/20-config-permissions.conf` перед каждым
  стартом от root восстанавливает владельца и режим файла;
- образец drop-in: `xray-main-hardening.conf.example`.

Проверка после изменения или перезагрузки:

```bash
sudo -u nobody test -r /usr/local/etc/xray/config.json
systemctl is-active xray xray-egress-194 xray-egress-130 xray-egress-149
ss -ltnp | grep -E ':443|:10085|:11041|:11042|:11043'
stat -c '%A %a %U:%G %n' /usr/local/etc/xray/config.json
```

При атомарной публикации нового конфига всегда задавать права явно, например
`install -o root -g nogroup -m 0640 NEW_CONFIG
/usr/local/etc/xray/config.json`; не оставлять результат обычного root-only
`mktemp` + `mv`.
