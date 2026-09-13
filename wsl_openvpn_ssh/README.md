# Ручной OpenVPN-over-SSH для WSL

Этот режим запускается только вручную и взаимоисключаем с тремя VLESS-профилями.

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
директиву `remote` OpenVPN config и привязывает SSH-forward непосредственно к
этому адресу. `netsh portproxy` не используется, поэтому права администратора
Windows не требуются. Схема сохраняет работу после `wsl --shutdown`, даже если
адрес WSL NAT изменился.

## Ручной запуск

Из обычного PowerShell без прав администратора:

    .\start-openvpn-ssh.example.ps1 -RemoteHost 192.0.2.194

Проверка в WSL:

    sudo openvpn-wsl status
    sudo openvpn-wsl check

Остановка и возврат обычного firewall:

    sudo openvpn-wsl stop

Linux wrapper останавливает все VLESS TUN, применяет отдельный OpenVPN fail-closed ruleset, запускает OpenVPN, проверяет exit и доказывает блокировку прямого eth0.

Переход на VLESS выполняется только одной из команд:

    sudo vless-wsl use 104-130
    sudo vless-wsl use 178-104-130
    sudo vless-wsl use 104-130-over-ssh

Команда VLESS сначала останавливает OpenVPN, затем соответствующий launcher применяет свой killswitch.

## Автовосстановление без ослабления kill switch

После ручного запуска PowerShell launcher создаёт скрытый watchdog и передаёт
ему уже открытый SSH-forward. Watchdog:

- следит за процессом SSH и здоровьем OpenVPN;
- проверяет внешний IP без обращения к DNS, чтобы временная задержка
  резолвера не вызывала цикл перезапусков;
- перезапускает OpenVPN только после двух последовательных неудачных
  проверок; завершение SSH-процесса обрабатывается немедленно;
- при обрыве заново создаёт SSH-forward и выполняет команду
  openvpn-wsl recover;
- перед любым перезапуском повторно применяет fail-closed ruleset;
- никогда не вызывает openvpn-wsl stop и не очищает firewall;
- завершается, если профиль вручную отключён или дистрибутив WSL остановлен.

Ручное разрешение хранится только в /run/openvpn-wsl.enabled. Поэтому после
wsl --shutdown оно исчезает: холодный старт WSL не запускает VPN или
watchdog. Команда openvpn-wsl start создаёт разрешение, openvpn-wsl stop
удаляет его. Внутренний recover отказывается запускаться без этого файла.

Установить openvpn-ssh-watchdog.example.ps1 рядом с Windows launcher и
передать его через -WatchdogPath, либо переименовать под локальный launcher.
Для полной остановки использовать stop-openvpn-ssh.example.ps1: он сначала
останавливает watchdog/SSH, затем отключает OpenVPN и возвращает обычный
firewall.

WSL-команда ../wsl-launchers/start-openvpn-194-130.sh вызывает установленный
на рабочем столе Windows launcher Run_VPN_Tunnel_new.ps1, поэтому включает и
SSH-forward и watchdog. Скрипты Windows работают без прав администратора.

Результат контролируемого failover-теста описан в FAILOVER_TEST.md.
