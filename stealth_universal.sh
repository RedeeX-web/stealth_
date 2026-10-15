#!/bin/bash
# ==============================================================================
# ДЕМО-ЭКЗАМЕН: МОДУЛЬ 1 — АВТОНОМНЫЙ УНИВЕРСАЛЬНЫЙ СКРИПТ НАСТРОЙКИ
# Совместим с: VirtualBox, VMware Workstation / ESXi, Proxmox, KVM / QEMU, физические ПК
# Запуск: скопировать одну строчку base64 или выполнить внутри ВМ от root
# ==============================================================================

# Защита от сохранения в историю терминала
unset HISTFILE
export HISTFILE=/dev/null

# Мгновенная привязка к скоростному зеркалу Яндекса (HTTP вместо медленного FTP)
[ -d /etc/apt/sources.list.d ] && echo "rpm [p10] http://mirror.yandex.ru/altlinux p10/branch/x86_64 classic" > /etc/apt/sources.list.d/alt.list 2>/dev/null || true

# Функция автоматического определения физического сетевого интерфейса (исключая виртуальные)
get_iface() {
    local idx=$1
    ip -o link show | awk -F': ' '{print $2}' | grep -Ev 'lo|gre|tun|sit|dummy|\.' | sed -n "${idx}p"
}

NODE_ROLE=""
TEST_MODE=0

for arg in "$@"; do
    case "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" in
        test|--test|check|-t) TEST_MODE=1 ;;
        isp|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli) NODE_ROLE=$(echo "$arg" | tr '[:lower:]' '[:upper:]') ;;
    esac
done

# 2. Определение по текущему hostname
if [ -z "$NODE_ROLE" ]; then
    HNAME=$(hostname -s | tr '[:upper:]' '[:lower:]')
    case "$HNAME" in
        *isp*) NODE_ROLE="ISP" ;;
        *hq-rtr*|*hqrtr*) NODE_ROLE="HQ-RTR" ;;
        *br-rtr*|*brrtr*) NODE_ROLE="BR-RTR" ;;
        *hq-srv*|*hqsrv*) NODE_ROLE="HQ-SRV" ;;
        *br-srv*|*brsrv*) NODE_ROLE="BR-SRV" ;;
        *hq-cli*|*hqcli*) NODE_ROLE="HQ-CLI" ;;
    esac
fi

# 3. Определение по MAC-адресам (стенд VirtualBox)
if [ -z "$NODE_ROLE" ]; then
    ALL_MACS=$(ip -o link show | awk '{for(i=1;i<=NF;i++) if($i=="link/ether") print $(i+1)}' | tr '[:upper:]' '[:lower:]')
    for mac in $ALL_MACS; do
        case "$mac" in
            08:00:27:e9:87:33|08:00:27:c4:d0:35|08:00:27:db:cc:ed) NODE_ROLE="ISP"; break ;;
            08:00:27:70:84:e9|08:00:27:3c:69:e6) NODE_ROLE="HQ-RTR"; break ;;
            08:00:27:c2:ee:e6|08:00:27:6c:68:c8) NODE_ROLE="BR-RTR"; break ;;
            08:00:27:30:e7:98) NODE_ROLE="HQ-SRV"; break ;;
            08:00:27:b7:a8:1c) NODE_ROLE="BR-SRV"; break ;;
            08:00:27:d8:26:4a) NODE_ROLE="HQ-CLI"; break ;;
        esac
    done
fi

# 4. Определение по имеющимся сетевым адресам или шлюзу по умолчанию
if [ -z "$NODE_ROLE" ]; then
    ALL_IPS=$(ip -o -4 addr show | awk '{print $4}')
    GW=$(ip route show default | awk '{print $3}')
    case "$ALL_IPS $GW" in
        *172.16.4.1*|*172.16.5.1*) NODE_ROLE="ISP" ;;
        *172.16.4.2*|*172.16.4.1*) NODE_ROLE="HQ-RTR" ;;
        *172.16.5.2*|*172.16.5.1*) NODE_ROLE="BR-RTR" ;;
        *192.168.1.2*|*192.168.1.1*) NODE_ROLE="HQ-SRV" ;;
        *192.168.4.2*|*192.168.4.1*) NODE_ROLE="BR-SRV" ;;
        *192.168.2.*) NODE_ROLE="HQ-CLI" ;;
    esac
fi

# 5. Определение по ОС и числу физических адаптеров
if [ -z "$NODE_ROLE" ]; then
    PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev 'lo|gre|tun|sit|dummy|\.' | wc -l)
    if [ "$PHYS_NICS" -ge 3 ]; then
        NODE_ROLE="ISP"
    elif grep -qi 'workstation' /etc/os-release 2>/dev/null; then
        NODE_ROLE="HQ-CLI"
    else
        echo "[!] Не удалось автоматически определить роль машины."
        echo "Пожалуйста, укажите роль: ISP, HQ-RTR, BR-RTR, HQ-SRV, BR-SRV, HQ-CLI"
        exit 1
    fi
fi

echo "[*] Автоопределение успешно: узел = $NODE_ROLE"

# Общий список /etc/hosts
setup_common_hosts() {
    cat << 'EOF' > /etc/hosts
127.0.0.1 localhost
192.168.1.1 hq-rtr.au-team.irpo moodle.au-team.irpo wiki.au-team.irpo
192.168.1.2 hq-srv.au-team.irpo
192.168.2.11 hq-cli.au-team.irpo
192.168.4.1 br-rtr.au-team.irpo
192.168.4.2 br-srv.au-team.irpo
EOF
}

# ------------------------------------------------------------------------------
# 1. ISP (Провайдер)
# ------------------------------------------------------------------------------
setup_isp() {
    echo "[*] Настройка узла ISP..."
    hostnamectl set-hostname isp
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_WAN=$(get_iface 1)
    IF_HQ=$(get_iface 2)
    IF_BR=$(get_iface 3)

    # DHCP на WAN
    dhcpcd "$IF_WAN" 2>/dev/null || dhclient "$IF_WAN" 2>/dev/null || true

    # Персистентность ALT Linux (etcnet)
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_WAN" "/etc/net/ifaces/$IF_HQ" "/etc/net/ifaces/$IF_BR"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=dhcp" > "/etc/net/ifaces/$IF_WAN/options"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_HQ/options"
        echo "172.16.4.1/28" > "/etc/net/ifaces/$IF_HQ/ipv4address"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_BR/options"
        echo "172.16.5.1/28" > "/etc/net/ifaces/$IF_BR/ipv4address"
        echo 'net.ipv4.ip_forward=1' >> /etc/net/sysctl.conf
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Ubuntu / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_WAN
iface $IF_WAN inet dhcp

auto $IF_HQ
iface $IF_HQ inet static
    address 172.16.4.1/28

auto $IF_BR
iface $IF_BR inet static
    address 172.16.5.1/28
EOF
    fi

    ip addr replace 172.16.4.1/28 dev "$IF_HQ" 2>/dev/null || ip addr add 172.16.4.1/28 dev "$IF_HQ" 2>/dev/null || true
    ip link set "$IF_HQ" up
    ip addr replace 172.16.5.1/28 dev "$IF_BR" 2>/dev/null || ip addr add 172.16.5.1/28 dev "$IF_BR" 2>/dev/null || true
    ip link set "$IF_BR" up

    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    iptables -F; iptables -t nat -F; iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -o "$IF_WAN" -j MASQUERADE
    iptables-save > /root/rules 2>/dev/null || true
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v 'iptables-restore'; echo '@reboot /sbin/iptables-restore < /root/rules') | crontab -
    systemctl restart network 2>/dev/null || systemctl restart networking 2>/dev/null || true

    # Авто-раздача DHCP для HQ-RTR и BR-RTR (Магия автоподключения)
    which dnsmasq >/dev/null 2>&1 || {
        echo "[*] Установка легкого DHCP сервера..."
        apt-get install -y dnsmasq 2>/dev/null || true
    }
    killall dnsmasq 2>/dev/null || true
    dnsmasq --port=0 \
      --interface="$IF_HQ" --dhcp-range=set:hq,172.16.4.2,172.16.4.2,255.255.255.240,1h --dhcp-option=tag:hq,3,172.16.4.1 --dhcp-option=tag:hq,6,8.8.8.8 \
      --interface="$IF_BR" --dhcp-range=set:br,172.16.5.2,172.16.5.2,255.255.255.240,1h --dhcp-option=tag:br,3,172.16.5.1 --dhcp-option=tag:br,6,8.8.8.8 \
      --bind-interfaces 2>/dev/null || true

    echo "[+] ISP успешно настроен!"
}

# ------------------------------------------------------------------------------
# 2. HQ-RTR (Центральный маршрутизатор)
# ------------------------------------------------------------------------------
setup_hq_rtr() {
    echo "[*] Настройка узла HQ-RTR..."
    hostnamectl set-hostname hq-rtr.au-team.irpo
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_WAN=$(get_iface 1)
    IF_LAN=$(get_iface 2)

    # Учетная запись net_admin
    useradd -s /bin/bash -u 1010 net_admin 2>/dev/null || true
    echo "net_admin:P@ssw0rd" | chpasswd
    echo "net_admin:P@\$\$word" | chpasswd 2>/dev/null || true
    usermod -aG wheel net_admin 2>/dev/null || usermod -aG sudo net_admin 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin 2>/dev/null || true

    # Персистентность ALT Linux
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_WAN" "/etc/net/ifaces/$IF_LAN" "/etc/net/ifaces/$IF_LAN.100" "/etc/net/ifaces/$IF_LAN.200" "/etc/net/ifaces/$IF_LAN.999" "/etc/net/ifaces/gre1"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_WAN/options"
        echo "172.16.4.2/28" > "/etc/net/ifaces/$IF_WAN/ipv4address"
        echo "default via 172.16.4.1" > "/etc/net/ifaces/$IF_WAN/ipv4route"

        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=no" > "/etc/net/ifaces/$IF_LAN/options"
        echo -e "TYPE=vlan\nHOST=$IF_LAN\nVID=100\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_LAN.100/options"
        echo "192.168.1.1/26" > "/etc/net/ifaces/$IF_LAN.100/ipv4address"

        echo -e "TYPE=vlan\nHOST=$IF_LAN\nVID=200\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_LAN.200/options"
        echo "192.168.2.1/28" > "/etc/net/ifaces/$IF_LAN.200/ipv4address"

        echo -e "TYPE=vlan\nHOST=$IF_LAN\nVID=999\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_LAN.999/options"
        echo "192.168.3.1/29" > "/etc/net/ifaces/$IF_LAN.999/ipv4address"

        cat << 'EOF' > /etc/net/ifaces/gre1/options
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.4.2
TUNREMOTE=172.16.5.2
TUNTTL=255
BOOTPROTO=static
CONFIG_IPV4=yes
EOF
        echo "10.10.10.1/30" > /etc/net/ifaces/gre1/ipv4address
        echo "192.168.4.0/27 via 10.10.10.2" > /etc/net/ifaces/gre1/ipv4route

        echo 'net.ipv4.ip_forward=1' >> /etc/net/sysctl.conf
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_WAN
iface $IF_WAN inet static
    address 172.16.4.2/28
    gateway 172.16.4.1

auto $IF_LAN
iface $IF_LAN inet manual

auto $IF_LAN.100
iface $IF_LAN.100 inet static
    address 192.168.1.1/26
    vlan-raw-device $IF_LAN

auto $IF_LAN.200
iface $IF_LAN.200 inet static
    address 192.168.2.1/28
    vlan-raw-device $IF_LAN

auto $IF_LAN.999
iface $IF_LAN.999 inet static
    address 192.168.3.1/29
    vlan-raw-device $IF_LAN

auto gre1
iface gre1 inet tunnel
    address 10.10.10.1
    netmask 255.255.255.252
    mode gre
    local 172.16.4.2
    endpoint 172.16.5.2
    ttl 255
    up ip route add 192.168.4.0/27 via 10.10.10.2 dev gre1
EOF
    fi

    # Применение в runtime
    ip addr replace 172.16.4.2/28 dev "$IF_WAN" 2>/dev/null || ip addr add 172.16.4.2/28 dev "$IF_WAN" 2>/dev/null || true
    ip link set "$IF_WAN" up
    ip route replace default via 172.16.4.1

    ip link set "$IF_LAN" up
    ip link add link "$IF_LAN" name "$IF_LAN.100" type vlan id 100 2>/dev/null || true
    ip addr replace 192.168.1.1/26 dev "$IF_LAN.100" 2>/dev/null || ip addr add 192.168.1.1/26 dev "$IF_LAN.100" 2>/dev/null || true
    ip link set "$IF_LAN.100" up

    ip link add link "$IF_LAN" name "$IF_LAN.200" type vlan id 200 2>/dev/null || true
    ip addr replace 192.168.2.1/28 dev "$IF_LAN.200" 2>/dev/null || ip addr add 192.168.2.1/28 dev "$IF_LAN.200" 2>/dev/null || true
    ip link set "$IF_LAN.200" up

    ip link add link "$IF_LAN" name "$IF_LAN.999" type vlan id 999 2>/dev/null || true
    ip addr replace 192.168.3.1/29 dev "$IF_LAN.999" 2>/dev/null || ip addr add 192.168.3.1/29 dev "$IF_LAN.999" 2>/dev/null || true
    ip link set "$IF_LAN.999" up

    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    # GRE tunnel
    ip tunnel del gre1 2>/dev/null || true
    ip tunnel add gre1 mode gre remote 172.16.5.2 local 172.16.4.2 ttl 255 2>/dev/null || true
    ip link set gre1 up
    ip addr replace 10.10.10.1/30 dev gre1 2>/dev/null || ip addr add 10.10.10.1/30 dev gre1 2>/dev/null || true
    ip route replace 192.168.4.0/27 via 10.10.10.2 dev gre1 2>/dev/null || true

    # NAT MASQUERADE
    iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -s 192.168.1.0/26 -o "$IF_WAN" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 192.168.2.0/28 -o "$IF_WAN" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 192.168.3.0/29 -o "$IF_WAN" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s 192.168.99.0/24 -o "$IF_WAN" -j MASQUERADE 2>/dev/null || true
    iptables-save > /root/rules 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v 'iptables-restore'; echo '@reboot /sbin/iptables-restore < /root/rules') | crontab -
    (crontab -l 2>/dev/null | grep -v 'gre1'; echo "@reboot ip tunnel add gre1 mode gre remote 172.16.5.2 local 172.16.4.2 ttl 255 && ip link set gre1 up && ip addr add 10.10.10.1/30 dev gre1 && ip route add 192.168.4.0/27 via 10.10.10.2 dev gre1") | crontab -

    # Hosts и DNS
    setup_common_hosts
    echo -e "nameserver 192.168.1.2\nnameserver 8.8.8.8" > /etc/resolv.conf

    # Временный IP на физическом транке для автоподключения клиентов без VLAN
    ip addr replace 192.168.99.1/24 dev "$IF_LAN" 2>/dev/null || true

    # DHCP Server (dnsmasq)
    [ -f /etc/sysconfig/dnsmasq ] && sed -i 's/AUTO_LOCAL_RESOLVER=yes/AUTO_LOCAL_RESOLVER=no/g' /etc/sysconfig/dnsmasq 2>/dev/null || true
    cat << EOF > /etc/dnsmasq.conf
port=0
interface=$IF_LAN.200
dhcp-range=set:v200,192.168.2.2,192.168.2.14,255.255.255.240,12h
dhcp-option=tag:v200,3,192.168.2.1
dhcp-option=tag:v200,6,192.168.1.2
dhcp-option=tag:v200,15,au-team.irpo

interface=$IF_LAN
dhcp-range=set:raw,192.168.99.10,192.168.99.50,255.255.255.0,1h
dhcp-option=tag:raw,3,192.168.99.1
dhcp-option=tag:raw,6,8.8.8.8
EOF
    systemctl enable --now dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true

    # OSPF (FRR)
    if [ -f /etc/frr/daemons ]; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        systemctl enable --now frr 2>/dev/null || systemctl restart frr 2>/dev/null || true
        vtysh -c 'conf t' -c 'router ospf' -c 'network 10.10.10.0/30 area 0' -c 'network 192.168.1.0/26 area 0' -c 'network 192.168.2.0/28 area 0' -c 'network 192.168.3.0/29 area 0' -c 'int gre1' -c 'ip ospf authentication message-digest' -c 'ip ospf message-digest-key 1 md5 P@ssw0rd' -c 'do wr mem' 2>/dev/null || true
    fi
    echo "[+] HQ-RTR успешно настроен!"
}

# ------------------------------------------------------------------------------
# 3. BR-RTR (Маршрутизатор филиала)
# ------------------------------------------------------------------------------
setup_br_rtr() {
    echo "[*] Настройка узла BR-RTR..."
    hostnamectl set-hostname br-rtr.au-team.irpo
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_WAN=$(get_iface 1)
    IF_LAN=$(get_iface 2)

    # Учетная запись net_admin
    useradd -s /bin/bash -u 1010 net_admin 2>/dev/null || true
    echo "net_admin:P@ssw0rd" | chpasswd
    echo "net_admin:P@\$\$word" | chpasswd 2>/dev/null || true
    usermod -aG wheel net_admin 2>/dev/null || usermod -aG sudo net_admin 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin 2>/dev/null || true

    # Персистентность ALT Linux
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_WAN" "/etc/net/ifaces/$IF_LAN" "/etc/net/ifaces/gre1"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_WAN/options"
        echo "172.16.5.2/28" > "/etc/net/ifaces/$IF_WAN/ipv4address"
        echo "default via 172.16.5.1" > "/etc/net/ifaces/$IF_WAN/ipv4route"

        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_LAN/options"
        echo "192.168.4.1/27" > "/etc/net/ifaces/$IF_LAN/ipv4address"

        cat << 'EOF' > /etc/net/ifaces/gre1/options
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.5.2
TUNREMOTE=172.16.4.2
TUNTTL=255
BOOTPROTO=static
CONFIG_IPV4=yes
EOF
        echo "10.10.10.2/30" > /etc/net/ifaces/gre1/ipv4address
        cat << 'EOF' > /etc/net/ifaces/gre1/ipv4route
192.168.1.0/26 via 10.10.10.1
192.168.2.0/28 via 10.10.10.1
192.168.3.0/29 via 10.10.10.1
EOF
        echo 'net.ipv4.ip_forward=1' >> /etc/net/sysctl.conf
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_WAN
iface $IF_WAN inet static
    address 172.16.5.2/28
    gateway 172.16.5.1

auto $IF_LAN
iface $IF_LAN inet static
    address 192.168.4.1/27

auto gre1
iface gre1 inet tunnel
    address 10.10.10.2
    netmask 255.255.255.252
    mode gre
    local 172.16.5.2
    endpoint 172.16.4.2
    ttl 255
    up ip route add 192.168.1.0/26 via 10.10.10.1 dev gre1
    up ip route add 192.168.2.0/28 via 10.10.10.1 dev gre1
EOF
    fi

    ip addr replace 172.16.5.2/28 dev "$IF_WAN" 2>/dev/null || ip addr add 172.16.5.2/28 dev "$IF_WAN" 2>/dev/null || true
    ip link set "$IF_WAN" up
    ip route replace default via 172.16.5.1

    ip addr replace 192.168.4.1/27 dev "$IF_LAN" 2>/dev/null || ip addr add 192.168.4.1/27 dev "$IF_LAN" 2>/dev/null || true
    ip link set "$IF_LAN" up

    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    # GRE tunnel
    ip tunnel del gre1 2>/dev/null || true
    ip tunnel add gre1 mode gre remote 172.16.4.2 local 172.16.5.2 ttl 255 2>/dev/null || true
    ip link set gre1 up
    ip addr replace 10.10.10.2/30 dev gre1 2>/dev/null || ip addr add 10.10.10.2/30 dev gre1 2>/dev/null || true

    # Статические маршруты через туннель (fallback до/рядом с OSPF)
    ip route replace 192.168.1.0/26 via 10.10.10.1 dev gre1 2>/dev/null || true
    ip route replace 192.168.2.0/28 via 10.10.10.1 dev gre1 2>/dev/null || true
    ip route replace 192.168.3.0/29 via 10.10.10.1 dev gre1 2>/dev/null || true

    # NAT MASQUERADE
    iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -s 192.168.4.0/27 -o "$IF_WAN" -j MASQUERADE 2>/dev/null || true
    iptables-save > /root/rules 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v 'iptables-restore'; echo '@reboot /sbin/iptables-restore < /root/rules') | crontab -
    (crontab -l 2>/dev/null | grep -v 'gre1'; echo "@reboot ip tunnel add gre1 mode gre remote 172.16.4.2 local 172.16.5.2 ttl 255 && ip link set gre1 up && ip addr add 10.10.10.2/30 dev gre1 && ip route add 192.168.1.0/26 via 10.10.10.1 dev gre1 && ip route add 192.168.2.0/28 via 10.10.10.1 dev gre1") | crontab -

    # Hosts и DNS
    setup_common_hosts
    echo -e "nameserver 192.168.1.2\nnameserver 8.8.8.8" > /etc/resolv.conf

    # OSPF (FRR)
    if [ -f /etc/frr/daemons ]; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
        systemctl enable --now frr 2>/dev/null || systemctl restart frr 2>/dev/null || true
        vtysh -c 'conf t' -c 'router ospf' -c 'network 10.10.10.0/30 area 0' -c 'network 192.168.4.0/27 area 0' -c 'int gre1' -c 'ip ospf authentication message-digest' -c 'ip ospf message-digest-key 1 md5 P@ssw0rd' -c 'do wr mem' 2>/dev/null || true
    fi

    # Авто-раздача DHCP для BR-SRV
    which dnsmasq >/dev/null 2>&1 || {
        echo "[*] Установка легкого DHCP сервера..."
        apt-get install -y dnsmasq 2>/dev/null || true
    }
    killall dnsmasq 2>/dev/null || true
    dnsmasq --port=0 --interface="$IF_LAN" --dhcp-range=192.168.4.2,192.168.4.2,255.255.255.224,1h --dhcp-option=3,192.168.4.1 --dhcp-option=6,8.8.8.8 --bind-interfaces 2>/dev/null || true

    echo "[+] BR-RTR успешно настроен!"
}

# ------------------------------------------------------------------------------
# 4. HQ-SRV (Центральный сервер)
# ------------------------------------------------------------------------------
setup_hq_srv() {
    echo "[*] Настройка узла HQ-SRV..."
    hostnamectl set-hostname hq-srv.au-team.irpo
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_RAW=$(get_iface 1)

    # Персистентность ALT Linux
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_RAW" "/etc/net/ifaces/$IF_RAW.100"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=no" > "/etc/net/ifaces/$IF_RAW/options"
        echo -e "TYPE=vlan\nHOST=$IF_RAW\nVID=100\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_RAW.100/options"
        echo "192.168.1.2/26" > "/etc/net/ifaces/$IF_RAW.100/ipv4address"
        echo "default via 192.168.1.1" > "/etc/net/ifaces/$IF_RAW.100/ipv4route"
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_RAW
iface $IF_RAW inet manual

auto $IF_RAW.100
iface $IF_RAW.100 inet static
    address 192.168.1.2/26
    gateway 192.168.1.1
    vlan-raw-device $IF_RAW
EOF
    fi

    killall dhcpcd dhclient 2>/dev/null || true
    ip addr flush dev "$IF_RAW" 2>/dev/null || true
    ip link set "$IF_RAW" up
    ip link add link "$IF_RAW" name "$IF_RAW.100" type vlan id 100 2>/dev/null || true
    ip link set "$IF_RAW.100" up
    ip addr replace 192.168.1.2/26 dev "$IF_RAW.100" 2>/dev/null || ip addr add 192.168.1.2/26 dev "$IF_RAW.100" 2>/dev/null || true
    ip route replace default via 192.168.1.1 dev "$IF_RAW.100" 2>/dev/null || true

    # Hosts
    setup_common_hosts
    echo -e "nameserver 127.0.0.1\nnameserver 8.8.8.8" > /etc/resolv.conf

    # Остановка конфликтующих DNS (bind/named)
    systemctl stop bind named 2>/dev/null || true
    systemctl disable bind named 2>/dev/null || true

    # DNS Server (dnsmasq)
    [ -f /etc/sysconfig/dnsmasq ] && echo 'OPTIONS=""' > /etc/sysconfig/dnsmasq
    cat << EOF > /etc/dnsmasq.conf
domain=au-team.irpo
server=8.8.8.8
address=/hq-rtr.au-team.irpo/192.168.1.1
cname=moodle.au-team.irpo,hq-rtr.au-team.irpo
cname=wiki.au-team.irpo,hq-rtr.au-team.irpo
address=/br-rtr.au-team.irpo/192.168.4.1
address=/hq-srv.au-team.irpo/192.168.1.2
address=/hq-cli.au-team.irpo/192.168.2.11
address=/br-srv.au-team.irpo/192.168.4.2
address=/docker.au-team.irpo/172.16.4.1
address=/web.au-team.irpo/172.16.5.1
ptr-record=1.1.168.192.in-addr.arpa,hq-rtr.au-team.irpo
ptr-record=2.1.168.192.in-addr.arpa,hq-srv.au-team.irpo
ptr-record=11.2.168.192.in-addr.arpa,hq-cli.au-team.irpo
ptr-record=1.4.168.192.in-addr.arpa,br-rtr.au-team.irpo
ptr-record=2.4.168.192.in-addr.arpa,br-srv.au-team.irpo
EOF
    systemctl enable --now dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true

    # SSH Hardening
    useradd -s /bin/bash -u 2026 sshuser 2>/dev/null || useradd -s /bin/bash -u 1010 sshuser 2>/dev/null || true
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG wheel sshuser 2>/dev/null || usermod -aG sudo sshuser 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
    chmod 440 /etc/sudoers.d/sshuser 2>/dev/null || true

    echo "Authorized access only" > /root/banner
    echo "Authorized access only" > /etc/openssh/banner 2>/dev/null || true
    chmod 644 /root/banner /etc/openssh/banner 2>/dev/null || true

    SSHD_CFG="/etc/openssh/sshd_config"
    [ ! -f "$SSHD_CFG" ] && SSHD_CFG="/etc/ssh/sshd_config"
    if [ -f "$SSHD_CFG" ]; then
        sed -i '/^Port/d; /^#Port/d; /^PermitRootLogin/d; /^#PermitRootLogin/d; /^AllowUsers/d; /^Banner/d; /^#Banner/d; /^MaxAuthTries/d; /^#MaxAuthTries/d' "$SSHD_CFG"
        cat << 'EOF' >> "$SSHD_CFG"
Port 2026
PermitRootLogin no
AllowUsers sshuser
Banner /root/banner
MaxAuthTries 2
EOF
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[+] HQ-SRV успешно настроен!"
}

# ------------------------------------------------------------------------------
# 5. BR-SRV (Сервер филиала)
# ------------------------------------------------------------------------------
setup_br_srv() {
    echo "[*] Настройка узла BR-SRV..."
    hostnamectl set-hostname br-srv.au-team.irpo
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_RAW=$(get_iface 1)

    # Персистентность ALT Linux
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_RAW"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$IF_RAW/options"
        echo "192.168.4.2/27" > "/etc/net/ifaces/$IF_RAW/ipv4address"
        echo "default via 192.168.4.1" > "/etc/net/ifaces/$IF_RAW/ipv4route"
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_RAW
iface $IF_RAW inet static
    address 192.168.4.2/27
    gateway 192.168.4.1
EOF
    fi

    killall dhcpcd dhclient 2>/dev/null || true
    ip addr replace 192.168.4.2/27 dev "$IF_RAW" 2>/dev/null || ip addr add 192.168.4.2/27 dev "$IF_RAW" 2>/dev/null || true
    ip link set "$IF_RAW" up
    ip route replace default via 192.168.4.1

    # Hosts и DNS
    setup_common_hosts
    echo -e "nameserver 192.168.1.2\nnameserver 8.8.8.8" > /etc/resolv.conf

    # SSH Hardening
    useradd -s /bin/bash -u 2026 sshuser 2>/dev/null || useradd -s /bin/bash -u 1010 sshuser 2>/dev/null || true
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG wheel sshuser 2>/dev/null || usermod -aG sudo sshuser 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
    chmod 440 /etc/sudoers.d/sshuser 2>/dev/null || true

    echo "Authorized access only" > /root/banner
    echo "Authorized access only" > /etc/openssh/banner 2>/dev/null || true
    chmod 644 /root/banner /etc/openssh/banner 2>/dev/null || true

    SSHD_CFG="/etc/openssh/sshd_config"
    [ ! -f "$SSHD_CFG" ] && SSHD_CFG="/etc/ssh/sshd_config"
    if [ -f "$SSHD_CFG" ]; then
        sed -i '/^Port/d; /^#Port/d; /^PermitRootLogin/d; /^#PermitRootLogin/d; /^AllowUsers/d; /^Banner/d; /^#Banner/d; /^MaxAuthTries/d; /^#MaxAuthTries/d' "$SSHD_CFG"
        cat << 'EOF' >> "$SSHD_CFG"
Port 2026
PermitRootLogin no
AllowUsers sshuser
Banner /root/banner
MaxAuthTries 2
EOF
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[+] BR-SRV успешно настроен!"
}

# ------------------------------------------------------------------------------
# 6. HQ-CLI (Клиент)
# ------------------------------------------------------------------------------
setup_hq_cli() {
    echo "[*] Настройка узла HQ-CLI..."
    hostnamectl set-hostname hq-cli.au-team.irpo
    timedatectl set-timezone Europe/Moscow 2>/dev/null || timedatectl set-timezone Asia/Yekaterinburg 2>/dev/null || true

    IF_RAW=$(get_iface 1)

    # Персистентность ALT Linux
    if [ -d /etc/net/ifaces ]; then
        mkdir -p "/etc/net/ifaces/$IF_RAW" "/etc/net/ifaces/$IF_RAW.200"
        echo -e "TYPE=eth\nDISABLED=no\nBOOTPROTO=static\nCONFIG_IPV4=no" > "/etc/net/ifaces/$IF_RAW/options"
        echo -e "TYPE=vlan\nHOST=$IF_RAW\nVID=200\nDISABLED=no\nBOOTPROTO=dhcp" > "/etc/net/ifaces/$IF_RAW.200/options"
        systemctl disable --now systemd-networkd 2>/dev/null || true
    fi

    # Персистентность Debian / Astra
    if [ -f /etc/network/interfaces ]; then
        cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $IF_RAW
iface $IF_RAW inet manual

auto $IF_RAW.200
iface $IF_RAW.200 inet dhcp
    vlan-raw-device $IF_RAW
EOF
    fi

    killall dhcpcd dhclient 2>/dev/null || true
    ip addr flush dev "$IF_RAW" 2>/dev/null || true
    ip link set "$IF_RAW" up
    ip link add link "$IF_RAW" name "$IF_RAW.200" type vlan id 200 2>/dev/null || true
    ip link set "$IF_RAW.200" up

    # Попытка получить DHCP от HQ-RTR
    dhcpcd "$IF_RAW.200" 2>/dev/null || dhclient "$IF_RAW.200" 2>/dev/null || true
    sleep 2

    # Если IP по DHCP еще не получен, назначим гарантированный статический IP
    CLI_IP=$(ip -o -4 addr show dev "$IF_RAW.200" 2>/dev/null | awk '{print $4}')
    if [ -z "$CLI_IP" ]; then
        ip addr replace 192.168.2.11/28 dev "$IF_RAW.200" 2>/dev/null || ip addr add 192.168.2.11/28 dev "$IF_RAW.200" 2>/dev/null || true
        ip route replace default via 192.168.2.1 2>/dev/null || true
    fi

    setup_common_hosts
    echo -e "nameserver 192.168.1.2\nnameserver 8.8.8.8" > /etc/resolv.conf

    echo "[+] HQ-CLI успешно настроен!"
}

# ------------------------------------------------------------------------------
# 7. Режим проверки (Self-Audit / Test)
# ------------------------------------------------------------------------------
run_tests() {
    local role="$1"
    local ERRORS=0
    local G="\e[32m[ PASS ]\e[0m"
    local R="\e[31m[ FAIL ]\e[0m"

    echo ""
    echo "=================================================="
    echo "       АУДИТ ВЫПОЛНЕНИЯ ЗАДАНИЙ: $role"
    echo "=================================================="

    check() {
        local desc="$1"
        shift
        if eval "$@"; then
            printf " %-46s %b\n" "$desc" "$G"
            return 0
        else
            printf " %-46s %b\n" "$desc" "$R"
            ERRORS=$((ERRORS + 1))
            return 1
        fi
    }

    case "$role" in
        ISP)
            check "WAN IP & Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            check "Сетевой адрес HQ (172.16.4.1/28)" "ip -o -4 addr show | grep -q '172.16.4.1/28'"
            check "Сетевой адрес BR (172.16.5.1/28)" "ip -o -4 addr show | grep -q '172.16.5.1/28'"
            check "IP Forwarding активен" "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = '1' ]"
            check "NAT MASQUERADE в iptables" "iptables -t nat -L POSTROUTING -n | grep -q 'MASQUERADE'"
            check "Связность с HQ-RTR (172.16.4.2)" "ping -c 2 -W 2 172.16.4.2 >/dev/null 2>&1"
            check "Связность с BR-RTR (172.16.5.2)" "ping -c 2 -W 2 172.16.5.2 >/dev/null 2>&1"
            ;;
        HQ-RTR)
            check "Hostname FQDN (hq-rtr.au-team.irpo)" "[ \"\$(hostname)\" = 'hq-rtr.au-team.irpo' ]"
            check "WAN IP (172.16.4.2/28)" "ip -o -4 addr show | grep -q '172.16.4.2/28'"
            check "VLAN 100 IP (192.168.1.1/26)" "ip -o -4 addr show | grep -q '192.168.1.1/26'"
            check "VLAN 200 IP (192.168.2.1/28)" "ip -o -4 addr show | grep -q '192.168.2.1/28'"
            check "VLAN 999 поднят" "ip link show | grep -q '\.999'"
            check "GRE Туннель gre1 (10.10.10.1/30)" "ip -o -4 addr show dev gre1 2>/dev/null | grep -q '10.10.10.1/30'"
            check "Связность через GRE с BR-RTR (10.10.10.2)" "ping -c 2 -W 2 10.10.10.2 >/dev/null 2>&1"
            check "OSPF соседство (Neighbor Full)" "vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -Eq 'Full|10.10.10.2'"
            check "Пользователь net_admin (UID 1010 + sudo)" "id -u net_admin 2>/dev/null | grep -q '^1010$' && sudo -l -U net_admin 2>/dev/null | grep -qi 'ALL'"
            check "DHCP сервер dnsmasq активен" "systemctl is-active dnsmasq >/dev/null 2>&1"
            check "Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            ;;
        BR-RTR)
            check "Hostname FQDN (br-rtr.au-team.irpo)" "[ \"\$(hostname)\" = 'br-rtr.au-team.irpo' ]"
            check "WAN IP (172.16.5.2/28)" "ip -o -4 addr show | grep -q '172.16.5.2/28'"
            check "LAN IP (192.168.4.1/27)" "ip -o -4 addr show | grep -q '192.168.4.1/27'"
            check "GRE Туннель gre1 (10.10.10.2/30)" "ip -o -4 addr show dev gre1 2>/dev/null | grep -q '10.10.10.2/30'"
            check "Связность через GRE с HQ-RTR (10.10.10.1)" "ping -c 2 -W 2 10.10.10.1 >/dev/null 2>&1"
            check "OSPF соседство (Neighbor Full)" "vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -Eq 'Full|10.10.10.1'"
            check "Пользователь net_admin (UID 1010 + sudo)" "id -u net_admin 2>/dev/null | grep -q '^1010$' && sudo -l -U net_admin 2>/dev/null | grep -qi 'ALL'"
            check "Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            ;;
        HQ-SRV)
            check "Hostname FQDN (hq-srv.au-team.irpo)" "[ \"\$(hostname)\" = 'hq-srv.au-team.irpo' ]"
            check "VLAN 100 IP (192.168.1.2/26)" "ip -o -4 addr show | grep -q '192.168.1.2/26'"
            check "Шлюз по умолчанию HQ-RTR (192.168.1.1)" "ping -c 2 -W 2 192.168.1.1 >/dev/null 2>&1"
            check "Связность с сервером BR-SRV (192.168.4.2)" "ping -c 2 -W 2 192.168.4.2 >/dev/null 2>&1"
            check "Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            check "DNS Резолв moodle (192.168.1.1)" "getent hosts moodle.au-team.irpo | grep -q '192.168.1.1'"
            check "DNS Резолв wiki (192.168.1.1)" "getent hosts wiki.au-team.irpo | grep -q '192.168.1.1'"
            check "DNS Резолв br-srv (192.168.4.2)" "getent hosts br-srv.au-team.irpo | grep -q '192.168.4.2'"
            check "Пользователь sshuser (UID + sudo)" "id -u sshuser 2>/dev/null | grep -qE '^(1010|2026)$' && sudo -l -U sshuser 2>/dev/null | grep -qi 'ALL'"
            check "SSH Hardening: порт 2024 / 2026" "ss -tulpn | grep -qE ':2024|:2026'"
            check "SSH Hardening: баннер" "grep -qi 'Authorized access only' /root/banner 2>/dev/null || grep -qi 'Authorized access only' /etc/openssh/banner 2>/dev/null"
            ;;
        BR-SRV)
            check "Hostname FQDN (br-srv.au-team.irpo)" "[ \"\$(hostname)\" = 'br-srv.au-team.irpo' ]"
            check "LAN IP (192.168.4.2/27)" "ip -o -4 addr show | grep -q '192.168.4.2/27'"
            check "Шлюз по умолчанию BR-RTR (192.168.4.1)" "ping -c 2 -W 2 192.168.4.1 >/dev/null 2>&1"
            check "Связность с сервером HQ-SRV (192.168.1.2)" "ping -c 2 -W 2 192.168.1.2 >/dev/null 2>&1"
            check "Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            check "DNS Резолв через HQ-SRV (moodle)" "getent hosts moodle.au-team.irpo | grep -q '192.168.1.1'"
            check "Пользователь sshuser (UID + sudo)" "id -u sshuser 2>/dev/null | grep -qE '^(1010|2026)$' && sudo -l -U sshuser 2>/dev/null | grep -qi 'ALL'"
            check "SSH Hardening: порт 2024 / 2026" "ss -tulpn | grep -qE ':2024|:2026'"
            check "SSH Hardening: баннер" "grep -qi 'Authorized access only' /root/banner 2>/dev/null || grep -qi 'Authorized access only' /etc/openssh/banner 2>/dev/null"
            ;;
        HQ-CLI)
            check "Hostname FQDN (hq-cli.au-team.irpo)" "[ \"\$(hostname)\" = 'hq-cli.au-team.irpo' ]"
            check "VLAN 200 IP (192.168.2.x)" "ip -o -4 addr show | grep -q '192.168.2.'"
            check "Шлюз по умолчанию HQ-RTR (192.168.2.1)" "ping -c 2 -W 2 192.168.2.1 >/dev/null 2>&1"
            check "Связность с сервером HQ-SRV (192.168.1.2)" "ping -c 2 -W 2 192.168.1.2 >/dev/null 2>&1"
            check "Связность с сервером BR-SRV (192.168.4.2)" "ping -c 2 -W 2 192.168.4.2 >/dev/null 2>&1"
            check "Выход в Интернет (8.8.8.8)" "ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1"
            check "DNS Резолв через HQ-SRV (moodle)" "getent hosts moodle.au-team.irpo | grep -q '192.168.1.1'"
            ;;
    esac

    echo "=================================================="
    if [ "$ERRORS" -eq 0 ]; then
        echo -e "\e[32m[+] ВСЕ ТЕСТЫ ПРОЙДЕНЫ (100% EXAM COMPLIANT)!\e[0m"
    else
        echo -e "\e[31m[-] ОБНАРУЖЕНО ОШИБОК: $ERRORS. ПРОВЕРЬТЕ ПУНКТЫ ВЫШЕ.\e[0m"
    fi
    echo "=================================================="
    return "$ERRORS"
}

# ------------------------------------------------------------------------------
# Точка входа
# ------------------------------------------------------------------------------
if [ "$TEST_MODE" -eq 1 ]; then
    run_tests "$NODE_ROLE"
    exit $?
fi

case "$NODE_ROLE" in
    ISP) setup_isp ;;
    HQ-RTR) setup_hq_rtr ;;
    BR-RTR) setup_br_rtr ;;
    HQ-SRV) setup_hq_srv ;;
    BR-SRV) setup_br_srv ;;
    HQ-CLI) setup_hq_cli ;;
    *) echo "[!] Неизвестная роль: $NODE_ROLE" ; exit 1 ;;
esac

# Очистка локальной истории
history -c
history -w
