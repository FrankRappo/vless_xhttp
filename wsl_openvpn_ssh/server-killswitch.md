# Server-side killswitch on exit-server (194)

Предотвращает утечку клиентского трафика через публичный IP сервера
при отказе WireGuard (wg130). Если wg130 умирает → трафик блокируется,
а не выходит через eth0.

## Как работает

```
OpenVPN клиенты (10.8.0.0/24)
  → tun0
    → policy routing (table 200) → wg130 → 130 → интернет  ✅ норма

Если wg130 упал:
  → policy routing ломается
    → fallback в main table → eth0
      → НО: FORWARD DROP для 10.8.0.0/24 → eth0
        → трафик ЗАБЛОКИРОВАН                              🔒 killswitch
```

## Правила (iptables)

```bash
# Policy routing: OpenVPN трафик → через wg130
ip rule add priority 100 from 10.8.0.0/24 iif tun0 lookup 200
ip route add default dev wg130 scope link table 200

# Killswitch: DROP если пытается через eth0
iptables -A FORWARD -s 10.8.0.0/24 -o eth0 -j DROP

# Исключение: direct-профиль (один клиент может через 194)
iptables -I FORWARD 1 -s 10.8.0.10/32 -o eth0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.8.0.10/32 -o eth0 -j MASQUERADE

# Разрешить OpenVPN вход
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I INPUT 1 -i eth0 -p tcp --dport 443 -j ACCEPT

# Разрешить forward tun0 ↔ wg130
iptables -A FORWARD -i tun0 -o wg130 -j ACCEPT
iptables -A FORWARD -i wg130 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

## Скрипт установки

```bash
#!/bin/sh
# Устанавливает managed-правила (идемпотентно — можно запускать повторно)

# Сброс старых
iptables -D INPUT -i eth0 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i tun0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.8.0.10/32 -o eth0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.8.0.0/24 -o eth0 -j DROP 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.8.0.10/32 -o eth0 -j MASQUERADE 2>/dev/null || true

# Установка
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I INPUT 1 -i eth0 -p tcp --dport 443 -j ACCEPT
iptables -I FORWARD 1 -s 10.8.0.10/32 -o eth0 -j ACCEPT
iptables -A FORWARD -s 10.8.0.0/24 -o eth0 -j DROP
iptables -t nat -A POSTROUTING -s 10.8.0.10/32 -o eth0 -j MASQUERADE
```

## Полный routing state (пример)

```
ip rule:
  50:  from 10.8.0.10 iif tun0 lookup main      ← direct-профиль
  100: from 10.8.0.0/24 iif tun0 lookup 200     ← все остальные → wg130

route table 200:
  default dev wg130 scope link

iptables FORWARD:
  -s 10.8.0.10/32 -o eth0 -j ACCEPT            ← direct исключение
  -s 10.8.0.0/24 -o eth0 -j DROP               ← KILLSWITCH
  -i tun0 -o wg130 -j ACCEPT                   ← нормальный путь
  -i wg130 -o tun0 -m state ESTABLISHED -j ACCEPT  ← возврат
```

## Важно

- Killswitch защищает от утечки IP сервера 194 при отказе wg130
- Без этого правила трафик клиентов вышел бы через публичный IP 194
- Правило `-j DROP` должно стоять ПОСЛЕ правила-исключения для direct-профиля
