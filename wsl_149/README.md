# Windows → 178 → 104 → 149

**Статус:** рабочий Windows-профиль; подключение по ссылке
подтверждено владельцем 2026-08-20.

Windows-профиль с китайским entry-hop `203.0.113.20` и персональным
выходом `203.0.113.40`:

```text
Windows
  → 203.0.113.20:443, VLESS + Reality + XHTTP stream-one
  → xray-egress-149.service / SOCKS 127.0.0.1:11043
  → 203.0.113.10:443, user exit149-2
  → out-149
  → 203.0.113.40:10443
  → Internet
```

Ожидаемый внешний IP: **`203.0.113.40`**.

## Что импортировать в Windows

Основной вариант — импортировать строку из
[`windows-178-104-149.txt`](./windows-178-104-149.txt) в актуальный
v2rayN. В v2rayN включить TUN или системный proxy в зависимости от
того, какой трафик нужно направлять в VPN.

Альтернатива — полный Xray JSON:

- `xray-windows-178-104-149.json`;
- SOCKS5: `127.0.0.1:20849`;
- HTTP proxy: `127.0.0.1:20850`;
- запуск: `START-windows-178-104-149.cmd`, если `xray.exe` лежит рядом.

Полный JSON не меняет системный proxy автоматически. Он не содержит
`freedom/direct` fallback; IPv6-назначения блокируются.

## Изоляция от других профилей

На `178` добавлены только:

- новый inbound-user `win178-149`;
- точное routing-правило `win178-149-out`;
- локальный outbound `out-104-149 → 127.0.0.1:11043`;
- отдельный `xray-egress-149.service` с `Restart=always`;
- отдельная health-проверка в общем 10-секундном watchdog.

Существующие `xray-egress-194.service`, `xray-egress-130.service`, их UUID,
порты и routing-правила не менялись. Основной Xray на `178` не
перезапускался: PID до/после добавления — `21927`.

Старая WSL-цепочка `WSL → 104 → 149` осталась без изменений:
`xray-exit149-104.json`, `sing-box-tun-to-149.json`, `exit149*.txt`.

## Серверные образцы

- `xray-egress-149.example.json` — точная копия egress-конфига;
- `xray-egress-149.service.example` — systemd unit.

Боевые пути на `178`:

```text
/usr/local/etc/xray/egress/egress-149.json
/etc/systemd/system/xray-egress-149.service
```

## Проверка

Проверка состоит из двух независимых фактов:

- серверная downstream-ветка SOCKS `11043` возвращает
  `203.0.113.40`;
- 2026-08-20 владелец подтвердил, что готовая ссылка
  `windows-178-104-149.txt` работает на целевом Windows.

Проверка на `178`:

```bash
systemctl is-active xray xray-egress-194 xray-egress-130 xray-egress-149
/usr/local/sbin/xray-egress-health
cat /run/xray-egress-health.state
```

Ожидаемо: `relay194=ok relay130=ok relay149=ok`.
