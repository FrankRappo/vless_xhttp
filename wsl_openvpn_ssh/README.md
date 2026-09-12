# Ручной OpenVPN-over-SSH для WSL

Этот режим запускается только вручную и взаимоисключаем с двумя VLESS-профилями.

Схема:

    WSL OpenVPN -> Windows 8443 -> SSH local forward
      -> 194:56777 -> OpenVPN 194:443 -> WireGuard -> exit 130

Холодный старт WSL не включает VPN и не применяет killswitch.

## Установка

1. Установить `openvpn-wsl.example.sh` как `/usr/local/bin/openvpn-wsl`.
2. Установить `../wsl_178_104_130/wsl-base-boot.example.sh` как
   `/usr/local/sbin/wsl-base-boot`.
3. Установить `../wsl_178_104_130/wsl.conf.example` как `/etc/wsl.conf`.
4. Установить OpenVPN client config как
   `/etc/openvpn/client/194_130wsl-over-ssh.conf`.
5. Хранить приватный SSH-ключ вне репозитория и заменить примерный RemoteHost
   в PowerShell launcher либо передать его параметром `-RemoteHost`.
6. Не устанавливать удалённые boot/cron launchers VLESS.

PowerShell launcher при каждом запуске подставляет текущий WSL gateway в
директиву `remote` OpenVPN config. Это сохраняет работу после `wsl --shutdown`,
даже если адрес WSL NAT изменился.

## Ручной запуск

Из PowerShell с правами администратора:

    .\start-openvpn-ssh.example.ps1 -RemoteHost 192.0.2.194

Проверка в WSL:

    sudo openvpn-wsl status
    sudo openvpn-wsl check

Остановка и возврат обычного firewall:

    sudo openvpn-wsl stop

Linux wrapper останавливает оба VLESS TUN, применяет отдельный OpenVPN fail-closed ruleset, запускает OpenVPN, проверяет exit и доказывает блокировку прямого eth0.

Переход на VLESS выполняется только одной из команд:

    sudo vless-wsl use 104-130
    sudo vless-wsl use 178-104-130

Команда VLESS сначала останавливает OpenVPN, затем соответствующий launcher применяет свой killswitch.
