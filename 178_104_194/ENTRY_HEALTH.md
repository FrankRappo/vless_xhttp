# Автовосстановление входа REALITY/XHTTP на 178

## Зачем нужен отдельный watchdog

`xray-egress-health.timer` проверяет изолированные выходы 178→104. Он не может
обнаружить состояние, при котором `xray.service` слушает `:443`, а новое
REALITY/XHTTP-подключение зависает или не передаёт данные.

После инцидента 2026-08-24 добавлена проверка самого публичного inbound. В ходе
инцидента:

- `203.0.113.20:22` и `:443` оставались доступны;
- выход `127.0.0.1:11041` стабильно давал `203.0.113.30` и около 63–66 Мбит/с;
- `www.example.com` прошёл 12/12 TLS 1.3 проб, затем повторную проверку примерно
  за 26 мс с самого 178;
- iPhone и Windows с одного внешнего клиентского адреса деградировали одновременно;
- TCP-сессии на участке клиентская сеть→178 показывали RTT до 1–2 секунд,
  `RTO=120s`, `cwnd=1` и
  повторные передачи.

Рестарт основного Xray заставил iPhone создать новые сессии. Внешнюю потерю
пакетов или плохой маршрут провайдера серверный рестарт устранить не может, но
watchdog автоматически исправляет зависший процесс/transport и не ждёт ручного
вмешательства.

## Как работает проверка

`xray-entry-health.timer` раз в 60 секунд запускает
`/usr/local/sbin/xray-entry-health`.

За один цикл создаются два настоящих подключения к `127.0.0.1:443`:

1. XHTTP `packet-up` — тот же режим, что у iPhone;
2. XHTTP `stream-one` — тот же режим, что у Windows.

Оба используют Reality SNI, ключ и `shortId` боевого входа. Отдельный UUID
`entry-health` маршрутизируется только к временному loopback HTTP responder
`127.0.0.1:18999`. Следующее правило блокирует любой другой трафик этого UUID,
поэтому canary не создаёт direct-fallback в Internet. Клиентский SOCKS
`127.0.0.1:11996` существует только во время проверки.

Политика восстановления:

- успех обоих режимов → счётчик ошибок обнуляется;
- три ошибки подряд → `xray run -test` боевого конфига;
- валидный конфиг → restart только `xray.service`;
- невалидный конфиг → restart запрещён;
- cooldown между автоматическими рестартами — 900 секунд;
- egress-процессы `xray-egress-*` не перезапускаются.

Обычное окно обнаружения — 3–4 минуты. Автоматическая смена Reality target не
выполняется: она потребовала бы одновременного обновления SNI во всех клиентских
профилях.

## Файлы на сервере

- `/usr/local/sbin/xray-entry-health`;
- `/etc/xray-entry-health/client-packet-up.json`;
- `/etc/xray-entry-health/client-stream-one.json`;
- `/etc/systemd/system/xray-entry-health.service`;
- `/etc/systemd/system/xray-entry-health.timer`;
- runtime state: `/run/xray-entry-health/state`.

Репозиторные образцы:

- `xray-entry-health.example.sh`;
- `xray-entry-health.service.example`;
- `xray-entry-health.timer.example`;
- `xray-entry-health-main.jq.example`;
- `xray-entry-health-client.jq.example`.

## Проверка и журнал

```bash
systemctl is-enabled xray-entry-health.timer
systemctl is-active xray-entry-health.timer
systemctl list-timers xray-entry-health.timer --all
cat /run/xray-entry-health/state
journalctl -u xray-entry-health.service --since '30 minutes ago'
```

Ручная двойная проверка:

```bash
/usr/local/sbin/xray-entry-health
```

Ожидаемый результат:

```text
entry=ok checked=...
```

Безопасная проверка failure-ветки без рестарта production:

```bash
XRAY_ENTRY_HEALTH_RUN_DIR=/run/xray-entry-health-dry \
XRAY_ENTRY_HEALTH_CLIENT_CONFIG_LIST=/nonexistent \
XRAY_ENTRY_HEALTH_THRESHOLD=1 \
XRAY_ENTRY_HEALTH_DRY_RUN=1 \
/usr/local/sbin/xray-entry-health
```

Ожидаемое состояние: `entry=restart-suppressed(dry-run)`.

## Отключение и rollback

Отключить автоматику без изменения Xray:

```bash
systemctl disable --now xray-entry-health.timer
```

Удалять служебного клиента из production-конфига необязательно: его credential
хранится только в root-only файлах и весь трафик, кроме loopback `:18999`,
блокируется. При полном rollback восстановить backup из
`/root/xray-backups/config.before-entry-health.*.json`, проверить его через
`xray run -test`, задать `root:nogroup 0640` и перезапустить `xray.service`.
