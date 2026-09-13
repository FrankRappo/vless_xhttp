# Ручной lifecycle VPN в WSL

Дата изменения: 2026-09-13.

После холодного старта WSL:

- OpenVPN не запускается;
- ни один из трёх VLESS-профилей не запускается;
- cron не восстанавливает VLESS;
- IPv4 и IPv6 firewall имеют обычные политики ACCEPT.

Ровно один режим включается явной командой:

    sudo openvpn-wsl start
    sudo vless-wsl use 104-130
    sudo vless-wsl use 178-104-130
    sudo vless-wsl use 104-130-over-ssh

OpenVPN и VLESS launchers сами останавливают конфликтующий TUN перед применением своего fail-closed ruleset. Профиль `104-130-over-ssh` оставляет на `eth0` только SSH к 104:22, а все остальные endpoints достигаются через базовый exit 130. Поэтому killswitch существует только после ручного запуска выбранного режима.

Для холодного сброса:

    wsl.exe --shutdown

После следующего запуска проверить:

    sudo iptables -S
    sudo ip6tables -S

Первые три строки каждой таблицы должны иметь policy ACCEPT, пока пользователь не выбрал VPN.
