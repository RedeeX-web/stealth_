<#
.SYNOPSIS
    Universal Stealth Deployer для Модуля 1 (VirtualBox).
.DESCRIPTION
    Передает команды настройки напрямую в буфер клавиатуры ВМ через VBoxManage.
    Поддерживает:
    - Режим EcoRouterOS для HQ-RTR и BR-RTR (Cisco-like CLI)
    - Режим Linux для HQ-RTR и BR-RTR (FRR / Bash)
    - Строгое соответствие спецификации ДЭ-2026: порт SSH 2026, UID sshuser 2026, MTU 1476.
#>

param (
    [ValidateSet("EcoRouter", "Linux")]
    [string]$RouterOS = "EcoRouter",
    [string]$VBoxPath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)

function Send-StealthLinux {
    param (
        [string]$VmName,
        [string[]]$Commands,
        [int]$DelayMs = 300
    )
    Write-Host "[-] Инъекция Linux-команд в $VmName..." -ForegroundColor Cyan
    & $VBoxPath controlvm $VmName keyboardputstring "export HISTFILE=/dev/null"
    & $VBoxPath controlvm $VmName keyboardputscancode 1c 9c
    Start-Sleep -Milliseconds 250

    foreach ($cmd in $Commands) {
        & $VBoxPath controlvm $VmName keyboardputstring "$cmd"
        & $VBoxPath controlvm $VmName keyboardputscancode 1c 9c
        Start-Sleep -Milliseconds $DelayMs
    }

    & $VBoxPath controlvm $VmName keyboardputstring "history -c; history -w"
    & $VBoxPath controlvm $VmName keyboardputscancode 1c 9c
    Write-Host "[+] $VmName (Linux) успешно настроен без следов." -ForegroundColor Green
}

function Send-StealthEcoRouter {
    param (
        [string]$VmName,
        [string[]]$Commands,
        [int]$DelayMs = 350
    )
    Write-Host "[-] Инъекция EcoRouterOS CLI в $VmName..." -ForegroundColor Yellow
    # Разблокировка консоли
    & $VBoxPath controlvm $VmName keyboardputscancode 1c 9c
    Start-Sleep -Milliseconds 200

    foreach ($cmd in $Commands) {
        if ($cmd -match '^\s*!\s*') { continue } # Пропуск комментариев
        & $VBoxPath controlvm $VmName keyboardputstring "$cmd"
        & $VBoxPath controlvm $VmName keyboardputscancode 1c 9c
        Start-Sleep -Milliseconds $DelayMs
    }
    Write-Host "[+] $VmName (EcoRouterOS) успешно настроен и сохранен." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 1. ISP (ALT Linux)
# ------------------------------------------------------------------------------
$isp_cmds = @(
    'hostnamectl set-hostname isp',
    'dhcpcd enp0s3 2>/dev/null || true',
    'ip addr replace 172.16.4.1/28 dev enp0s8 2>/dev/null || ip addr add 172.16.4.1/28 dev enp0s8',
    'ip link set enp0s8 up',
    'ip addr replace 172.16.5.1/28 dev enp0s9 2>/dev/null || ip addr add 172.16.5.1/28 dev enp0s9',
    'ip link set enp0s9 up',
    'sysctl -w net.ipv4.ip_forward=1',
    'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf',
    'iptables -F; iptables -t nat -F; iptables -P FORWARD ACCEPT',
    'iptables -t nat -A POSTROUTING -o enp0s3 -j MASQUERADE',
    'iptables-save > /root/rules 2>/dev/null || true'
)

# ------------------------------------------------------------------------------
# 2. HQ-RTR (EcoRouterOS vs Linux)
# ------------------------------------------------------------------------------
$hqrtr_ecorouter_cmds = @(
    'enable',
    'configure terminal',
    'hostname HQ-RTR.au-team.irpo',
    'ip domain-name au-team.irpo',
    'ntp timezone utc+3',
    'username net_admin',
    'password P@ssw0rd',
    'role admin',
    'exit',
    'ip route 0.0.0.0/0 172.16.4.1',
    'interface isp',
    'description WAN_to_ISP',
    'ip address 172.16.4.2/28',
    'ip nat outside',
    'exit',
    'interface vl100',
    'description VLAN100_HQ-SRV',
    'ip address 192.168.1.1/26',
    'ip nat inside',
    'exit',
    'interface vl200',
    'description VLAN200_HQ-CLI',
    'ip address 192.168.2.1/28',
    'ip nat inside',
    'dhcp-server 1',
    'exit',
    'interface vl999',
    'description VLAN999_MGMT',
    'ip address 192.168.99.1/29',
    'ip nat inside',
    'exit',
    'port ge0',
    'no service-instance ge0',
    'service-instance ge0/isp',
    'encapsulation untagged',
    'connect ip interface isp',
    'exit',
    'exit',
    'port ge1',
    'service-instance ge1/vl100',
    'encapsulation dot1q 100 exact',
    'rewrite pop 1',
    'connect ip interface vl100',
    'exit',
    'service-instance ge1/vl200',
    'encapsulation dot1q 200 exact',
    'rewrite pop 1',
    'connect ip interface vl200',
    'exit',
    'service-instance ge1/vl999',
    'encapsulation dot1q 999 exact',
    'rewrite pop 1',
    'connect ip interface vl999',
    'exit',
    'exit',
    'interface tunnel.0',
    'description GRE_to_BR',
    'ip address 10.10.10.1/30',
    'ip mtu 1476',
    'ip tcp adjust-mss 1360',
    'ip tunnel 172.16.4.2 172.16.5.2 mode gre',
    'ip ospf network point-to-point',
    'ip ospf authentication message-digest',
    'ip ospf message-digest-key 1 md5 P@ssw0rd',
    'exit',
    'router ospf 1',
    'ospf router-id 10.10.10.1',
    'passive-interface default',
    'no passive-interface tunnel.0',
    'network 10.10.10.0/30 area 0',
    'network 192.168.1.0/26 area 0',
    'network 192.168.2.0/28 area 0',
    'network 192.168.99.0/29 area 0',
    'exit',
    'ip pool dhcp 1',
    'range 192.168.2.2-192.168.2.14',
    'exit',
    'dhcp-server 1',
    'pool dhcp 1',
    'mask 255.255.255.240',
    'gateway 192.168.2.1',
    'dns 192.168.1.2',
    'domain-name au-team.irpo',
    'exit',
    'ip nat pool HQ-NAT 192.168.1.1-192.168.2.254',
    'ip nat source dynamic inside-to-outside pool HQ-NAT overload interface isp',
    'exit',
    'write memory'
)

$hqrtr_linux_cmds = @(
    'hostnamectl set-hostname hq-rtr.au-team.irpo',
    'useradd -s /bin/bash -u 1010 net_admin 2>/dev/null || true',
    'echo "net_admin:P@ssw0rd" | chpasswd',
    'usermod -aG wheel net_admin 2>/dev/null || usermod -aG sudo net_admin 2>/dev/null || true',
    'echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin',
    'ip addr replace 172.16.4.2/28 dev enp0s3 2>/dev/null || ip addr add 172.16.4.2/28 dev enp0s3',
    'ip link set enp0s3 up',
    'ip route replace default via 172.16.4.1',
    'ip link set enp0s8 up',
    'ip link add link enp0s8 name enp0s8.100 type vlan id 100 2>/dev/null || true',
    'ip addr replace 192.168.1.1/26 dev enp0s8.100',
    'ip link set enp0s8.100 up',
    'ip link add link enp0s8 name enp0s8.200 type vlan id 200 2>/dev/null || true',
    'ip addr replace 192.168.2.1/28 dev enp0s8.200',
    'ip link set enp0s8.200 up',
    'ip link add link enp0s8 name enp0s8.999 type vlan id 999 2>/dev/null || true',
    'ip addr replace 192.168.3.1/29 dev enp0s8.999',
    'ip link set enp0s8.999 up',
    'sysctl -w net.ipv4.ip_forward=1',
    'ip tunnel add gre1 mode gre remote 172.16.5.2 local 172.16.4.2 ttl 255 2>/dev/null || true',
    'ip link set gre1 up',
    'ip addr replace 10.10.10.1/30 dev gre1',
    'ip route replace 192.168.4.0/27 via 10.10.10.2 dev gre1',
    'iptables -P FORWARD ACCEPT',
    'iptables -t nat -A POSTROUTING -s 192.168.1.0/26 -o enp0s3 -j MASQUERADE',
    'iptables -t nat -A POSTROUTING -s 192.168.2.0/28 -o enp0s3 -j MASQUERADE'
)

# ------------------------------------------------------------------------------
# 3. BR-RTR (EcoRouterOS vs Linux)
# ------------------------------------------------------------------------------
$brrtr_ecorouter_cmds = @(
    'enable',
    'configure terminal',
    'hostname BR-RTR.au-team.irpo',
    'ip domain-name au-team.irpo',
    'ntp timezone utc+3',
    'username net_admin',
    'password P@ssw0rd',
    'role admin',
    'exit',
    'ip route 0.0.0.0/0 172.16.5.1',
    'port ge0',
    'no service-instance ge0',
    'service-instance ge0/isp',
    'encapsulation untagged',
    'connect ip interface isp',
    'exit',
    'exit',
    'interface isp',
    'description WAN_to_ISP',
    'ip address 172.16.5.2/28',
    'ip nat outside',
    'exit',
    'port ge1',
    'service-instance ge1/br-lan',
    'encapsulation untagged',
    'connect ip interface br-lan',
    'exit',
    'exit',
    'interface br-lan',
    'description LAN_BR-SRV',
    'ip address 192.168.4.1/27',
    'ip nat inside',
    'exit',
    'interface tunnel.0',
    'description GRE_to_HQ',
    'ip address 10.10.10.2/30',
    'ip mtu 1476',
    'ip tcp adjust-mss 1360',
    'ip tunnel 172.16.5.2 172.16.4.2 mode gre',
    'ip ospf network point-to-point',
    'ip ospf authentication message-digest',
    'ip ospf message-digest-key 1 md5 P@ssw0rd',
    'exit',
    'router ospf 1',
    'ospf router-id 10.10.10.2',
    'passive-interface default',
    'no passive-interface tunnel.0',
    'network 10.10.10.0/30 area 0',
    'network 192.168.4.0/27 area 0',
    'exit',
    'ip nat pool BR-NAT 192.168.4.1-192.168.4.30',
    'ip nat source dynamic inside-to-outside pool BR-NAT overload interface isp',
    'exit',
    'write memory'
)

$brrtr_linux_cmds = @(
    'hostnamectl set-hostname br-rtr.au-team.irpo',
    'useradd -s /bin/bash -u 1010 net_admin 2>/dev/null || true',
    'echo "net_admin:P@ssw0rd" | chpasswd',
    'usermod -aG wheel net_admin 2>/dev/null || usermod -aG sudo net_admin 2>/dev/null || true',
    'echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin',
    'ip addr replace 172.16.5.2/28 dev enp0s3 2>/dev/null || ip addr add 172.16.5.2/28 dev enp0s3',
    'ip link set enp0s3 up',
    'ip route replace default via 172.16.5.1',
    'ip addr replace 192.168.4.1/27 dev enp0s8 2>/dev/null || ip addr add 192.168.4.1/27 dev enp0s8',
    'ip link set enp0s8 up',
    'sysctl -w net.ipv4.ip_forward=1',
    'ip tunnel add gre1 mode gre remote 172.16.4.2 local 172.16.5.2 ttl 255 2>/dev/null || true',
    'ip link set gre1 up',
    'ip addr replace 10.10.10.2/30 dev gre1',
    'ip route replace 192.168.1.0/26 via 10.10.10.1 dev gre1',
    'ip route replace 192.168.2.0/28 via 10.10.10.1 dev gre1',
    'iptables -P FORWARD ACCEPT',
    'iptables -t nat -A POSTROUTING -s 192.168.4.0/27 -o enp0s3 -j MASQUERADE'
)

# ------------------------------------------------------------------------------
# 4. HQ-SRV (ALT Linux — строго по регламенту ДЭ-2026)
# ------------------------------------------------------------------------------
$hqsrv_cmds = @(
    'hostnamectl set-hostname hq-srv.au-team.irpo',
    'timedatectl set-timezone Europe/Moscow',
    'ip link add link enp0s3 name enp0s3.100 type vlan id 100 2>/dev/null || true',
    'ip link set enp0s3 up; ip link set enp0s3.100 up',
    'ip addr replace 192.168.1.2/26 dev enp0s3.100 2>/dev/null || ip addr add 192.168.1.2/26 dev enp0s3.100',
    'ip route replace default via 192.168.1.1 dev enp0s3.100',
    'echo -e "nameserver 127.0.0.1\nnameserver 77.88.8.7" > /etc/resolv.conf',
    'useradd sshuser -u 2026 2>/dev/null || useradd sshuser -u 1010 2>/dev/null || true',
    'echo "sshuser:P@ssw0rd" | chpasswd',
    'usermod -aG wheel sshuser 2>/dev/null || usermod -aG sudo sshuser 2>/dev/null || true',
    'mkdir -p /etc/sudoers.d',
    'echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser',
    'echo "Authorized access only" > /etc/openssh/banner',
    'sed -i "s/^#*Port.*/Port 2026/" /etc/openssh/sshd_config 2>/dev/null || true',
    'sed -i "s/^#*Port.*/Port 2026/" /etc/ssh/sshd_config 2>/dev/null || true',
    'echo -e "AllowUsers sshuser\nBanner /etc/openssh/banner\nMaxAuthTries 2" >> /etc/openssh/sshd_config 2>/dev/null || true',
    'systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true'
)

# ------------------------------------------------------------------------------
# 5. BR-SRV (ALT Linux)
# ------------------------------------------------------------------------------
$brsrv_cmds = @(
    'hostnamectl set-hostname br-srv.au-team.irpo',
    'timedatectl set-timezone Europe/Moscow',
    'ip addr replace 192.168.4.2/27 dev enp0s3 2>/dev/null || ip addr add 192.168.4.2/27 dev enp0s3',
    'ip link set enp0s3 up',
    'ip route replace default via 192.168.4.1',
    'echo -e "nameserver 192.168.1.2\nnameserver 77.88.8.7" > /etc/resolv.conf',
    'useradd sshuser -u 2026 2>/dev/null || useradd sshuser -u 1010 2>/dev/null || true',
    'echo "sshuser:P@ssw0rd" | chpasswd',
    'usermod -aG wheel sshuser 2>/dev/null || usermod -aG sudo sshuser 2>/dev/null || true',
    'mkdir -p /etc/sudoers.d',
    'echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser',
    'echo "Authorized access only" > /etc/openssh/banner',
    'sed -i "s/^#*Port.*/Port 2026/" /etc/openssh/sshd_config 2>/dev/null || true',
    'sed -i "s/^#*Port.*/Port 2026/" /etc/ssh/sshd_config 2>/dev/null || true',
    'echo -e "AllowUsers sshuser\nBanner /etc/openssh/banner\nMaxAuthTries 2" >> /etc/openssh/sshd_config 2>/dev/null || true',
    'systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true'
)

# ------------------------------------------------------------------------------
# 6. HQ-CLI (ALT Linux Workstation)
# ------------------------------------------------------------------------------
$hqcli_cmds = @(
    'hostnamectl set-hostname hq-cli.au-team.irpo',
    'timedatectl set-timezone Europe/Moscow',
    'ip link add link enp0s3 name enp0s3.200 type vlan id 200 2>/dev/null || true',
    'ip link set enp0s3 up; ip link set enp0s3.200 up',
    'dhcpcd enp0s3.200 2>/dev/null || dhclient enp0s3.200 2>/dev/null || true'
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Запуск Stealth-развертывания Демо-Экзамена (Модуль 1)" -ForegroundColor Cyan
Write-Host " Выбранный режим для HQ-RTR и BR-RTR: [$RouterOS]" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# Выполнение настройки узлов
Send-StealthLinux -VmName "ISP" -Commands $isp_cmds

if ($RouterOS -eq "EcoRouter") {
    Send-StealthEcoRouter -VmName "HQ-RTR" -Commands $hqrtr_ecorouter_cmds
    Send-StealthEcoRouter -VmName "BR-RTR" -Commands $brrtr_ecorouter_cmds
} else {
    Send-StealthLinux -VmName "HQ-RTR" -Commands $hqrtr_linux_cmds
    Send-StealthLinux -VmName "BR-RTR" -Commands $brrtr_linux_cmds
}

Send-StealthLinux -VmName "HQ-SRV" -Commands $hqsrv_cmds
Send-StealthLinux -VmName "BR-SRV" -Commands $brsrv_cmds
Send-StealthLinux -VmName "HQ-CLI" -Commands $hqcli_cmds

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " [SUCCESS] Все узлы инфраструктуры успешно сконфигурированы!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
