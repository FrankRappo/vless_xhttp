# WSL: VLESS 104→130 внутри SSH к 104

Этот ручной профиль нужен, когда провайдер блокирует прямой Reality/XHTTP к
entry `203.0.113.10:443`, но пропускает SSH к тому же серверу.

```text
весь трафик WSL
  → tun-vlessssh130
  → sing-box
  → Xray SOCKS 127.0.0.1:18130
  → VLESS/Reality/XHTTP 127.0.0.1:18443
  → SSH local forward к 203.0.113.10:22
  → Xray 127.0.0.1:443 на 104
  → существующий маршрут client1
  → exit 198.51.100.130
```

Новый серверный VLESS-пользователь не создаётся: runtime-конфигурация Xray
наследует существующий профиль `client1`, меняя только адрес транспорта на
локальный SSH-forward.

## Порты и интерфейс

- `127.0.0.1:18130` — отдельный SOCKS Xray;
- `127.0.0.1:18443` — отдельный SSH local forward;
- `tun-vlessssh130`, `172.19.131.1/30` — отдельный TUN.

Порты слушают только loopback и не конфликтуют с обычными проектными портами
WSL. Проекты могут поднимать любые свободные порты. Их исходящие соединения,
включая подключения к дополнительным SSH/OpenVPN/WireGuard-туннелям, сначала
идут через базовый exit `198.51.100.130`. Дополнительному endpoint нельзя
добавлять прямое исключение через `eth0`; тогда итоговый внешний IP может быть
IP верхнего туннеля, но порядок остаётся `WSL → 130 → верхний туннель`.

## Fail-closed и восстановление

Kill switch разрешает на `eth0` ровно один bootstrap-поток:
`203.0.113.10:22/tcp`. Loopback и `tun+` разрешены, широких правил
`ESTABLISHED,RELATED` нет, IPv6 полностью закрыт.
Остановка SSH, Xray или sing-box поэтому не даёт прямого fallback.

Watchdog запускается только после явного выбора профиля, проверяет структуру
каждые 15 секунд, немедленно восстанавливает упавший процесс и после двух
ошибок восстанавливает деградировавший маршрут. После холодного запуска WSL
профиль, watchdog и kill switch не включаются автоматически.

## Установка примера

Перед установкой замените example IP/пути и подготовьте отдельный restricted
SSH-ключ, которому на 104 разрешён только forward к `127.0.0.1:443`.
Рекомендуемая строка `authorized_keys`:

```text
command="/bin/false",restrict,port-forwarding,permitopen="127.0.0.1:443" ssh-ed25519 <PUBLIC_KEY> vless-wsl-104-130-over-ssh
```

Приватный ключ устанавливается root-владельцем с mode `0600` в
`/etc/vless-wsl/ssh104130_ed25519`. Проверенный host key 104 записывается в
root-owned `/etc/vless-wsl/known_hosts`; `StrictHostKeyChecking` не отключается.

```bash
sudo install -m 0755 killswitch-vless-104-ssh.example.sh /usr/local/bin/killswitch-vless-104-ssh
sudo install -m 0755 vless104130-ssh.example.sh /usr/local/bin/vless104130-ssh
sudo install -m 0755 vless104130-ssh-watchdog.example.sh /usr/local/bin/vless104130-ssh-watchdog
sudo install -m 0755 ../wsl_178_104_130/vless-wsl.example.sh /usr/local/bin/vless-wsl
sudo install -m 0755 ../wsl_openvpn_ssh/openvpn-wsl.example.sh /usr/local/bin/openvpn-wsl
sudo /usr/local/bin/vless-wsl use 104-130-over-ssh
```

Проверки:

```bash
sudo /usr/local/bin/vless-wsl status
sudo /usr/local/bin/vless-wsl check
sudo /usr/local/bin/vless-wsl test-fail-closed
```

## Проверено

Live-приёмка 2026-09-13 подтвердила: Xray и sing-box принимают сгенерированные
runtime-конфиги; прямого XHTTP-соединения к 104:443 нет; внешний transport —
один SSH к 104:22; base/default exit равен 130; остановка TUN блокирует default,
`eth0` и IPv6; watchdog восстанавливает убитый SSH без снятия kill switch.
Отдельное SSH-подключение проекта к следующему VPS увидело source IP базового
exit 130, то есть endpoint верхнего туннеля не обошёл базовый VPN.
