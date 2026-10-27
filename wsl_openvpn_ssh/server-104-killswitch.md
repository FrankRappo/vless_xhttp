# Server-side killswitch: entry-server (104)

Полная политика DROP с allow-листом. Предотвращает утечку трафика через
публичный IP входного сервера при отказе туннелей к exit-серверам.

## Как работает

```
VPN клиенты → 104:443 (VLESS вход)
  → tunnel-balancer → SSH туннели → exit-сервер → интернет   ← норма

Если SSH туннели к exit умирают:
  → xray watchdog перезапускает туннели
  → трафик ждёт (в буфере)
  → НЕ выходит через публичный IP 104                           ← killswitch

Почему не выходит:
  OUTPUT policy = DROP
  Разрешены только: lo, wg130, exit:ssh-port, DNS, HTTP, HTTPS, NTP, ICMP
  Нет правила "OUTPUT -o eth0 -j ACCEPT" → всё через eth0 BLOCKED
```

## Ключевые правила

```bash
# Всё закрыто по умолчанию
-P OUTPUT DROP

# Разрешено ТОЛЬКО:
-A OUTPUT -o lo -j ACCEPT                                      # localhost
-A OUTPUT -o wg130 -j ACCEPT                                   # WireGuard к 130
-A OUTPUT -d <exit-ip>/32 --dport <exit-ssh> -j ACCEPT         # SSH к exit
-A OUTPUT --dport 53 -j ACCEPT                                 # DNS
-A OUTPUT --dport 443 -j ACCEPT                                # HTTPS (LE renew)
-A OUTPUT -m mark --mark 104 -j ACCEPT                         # direct-exit профиль
# Всё остальное через eth0: DROP (killswitch)
```

## Автозагрузка

- `iptables-persistent` + `netfilter-persistent` (enabled)
- Правила загружаются при старте из `/etc/iptables/rules.v4` + `rules.v6`
- Переживает ребут сервера

## Проверка

```bash
# Текущие правила:
iptables -L OUTPUT -n -v

# Должно быть:
# Policy: DROP
# ACCEPT для lo, wg130, exit:ssh, DNS, HTTP, HTTPS, NTP, ICMP, mark-104
# Никаких других ACCEPT через eth0
```
