# Double SSH profiles: WSL → SSH 217 (VLESS) → SSH 104 → exit

Схема:
```
WSL (OpenVPN/VLESS client)
  → SSH :22 на relay-сервере
    → VLESS/Reality внутри SSH туннеля → на relay
      → VLESS от relay → на entry-сервер
        → SSH туннель → на exit-сервер
          → интернет
```

Два профиля:
- `217-ssh-104-194` — exit 194
- `217-ssh-104-149` — exit 149

## Killswitch
- Разрешён ТОЛЬКО SSH к relay (порт 22) + tun+
- Всё остальное DROP (fail-closed)
- См. `killswitch-vless-217-ssh.example.sh`

## Запуск
```bash
cd /work/vpn
sudo ./wsl-vpn 217ssh194   # exit 194
sudo ./wsl-vpn 217ssh149   # exit 149
```
