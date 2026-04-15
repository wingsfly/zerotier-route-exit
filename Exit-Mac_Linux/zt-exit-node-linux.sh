#!/bin/bash

# ZeroTier Exit Node Script for Linux
# Tested on: Debian/Ubuntu
# Place at: /usr/local/bin/zt-exit-node.sh
# Usage: zt-exit-node.sh {start|stop|status|restart}

ZT_NET="10.66.66.0/24"
# Detect ZeroTier interface (zt* naming on Linux)
ZT_IFACE=$(zerotier-cli listnetworks 2>/dev/null | grep -oE 'zt[a-z0-9]+' | head -1)
# Detect default WAN interface
WAN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

STATE_FILE="/tmp/zt-exit.state"
DNSMASQ_CONF="/etc/dnsmasq.d/zt-exit.conf"

start() {
    if [ -f "$STATE_FILE" ]; then
        echo "[!] Already running. Run stop first."
        exit 1
    fi

    echo "[+] Starting Linux exit node..."

    # Refresh interface detection inside function (may not be up at script load time)
    ZT_IFACE=$(zerotier-cli listnetworks 2>/dev/null | grep -oE 'zt[a-z0-9]+' | head -1)
    WAN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

    if [ -z "$ZT_IFACE" ]; then
        echo "[-] ZeroTier interface not found. Is ZeroTier running and joined?"
        exit 1
    fi
    echo "[+] ZeroTier interface: $ZT_IFACE"
    echo "[+] WAN interface: $WAN_IFACE"

    # Wait for gateway reachability
    ZT_IP=$(ip addr show "$ZT_IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
    if [ -z "$ZT_IP" ]; then
        echo "[-] Could not get ZeroTier IP from interface $ZT_IFACE."
        exit 1
    fi
    echo "[+] ZeroTier IP: $ZT_IP"

    # -- Enable IP forwarding --
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    # Persist across reboots
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # -- NAT via iptables --
    iptables -t nat -A POSTROUTING -s "$ZT_NET" -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$ZT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "[+] iptables NAT enabled."

    # -- DNS via dnsmasq --
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "[!] dnsmasq not found. Installing..."
        apt-get install -y dnsmasq >/dev/null 2>&1 || \
        yum install -y dnsmasq >/dev/null 2>&1 || \
        { echo "[-] Could not install dnsmasq. Please install manually."; exit 1; }
    fi

    # Configure dnsmasq to listen on ZeroTier interface only
    mkdir -p /etc/dnsmasq.d
    cat > "$DNSMASQ_CONF" << EOF
# Managed by zt-exit-node.sh - do not edit manually
bind-interfaces
listen-address=$ZT_IP
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=$ZT_IFACE
EOF

    # Restart dnsmasq and verify
    systemctl restart dnsmasq
    sleep 1

    if systemctl is-active --quiet dnsmasq && \
       nc -z -w1 "$ZT_IP" 53 2>/dev/null; then
        echo "[+] dnsmasq started, listening on $ZT_IP:53"
    else
        echo "[-] dnsmasq failed to start. Check: journalctl -u dnsmasq"
        exit 1
    fi

    # Save state
    {
        echo "ZT_IFACE=$ZT_IFACE"
        echo "ZT_IP=$ZT_IP"
        echo "WAN_IFACE=$WAN_IFACE"
        echo "STARTED=$(date)"
    } > "$STATE_FILE"

    echo "[+] Done. Linux node is now acting as ZeroTier exit node."
    echo "[+] ZeroTier IP: $ZT_IP"
}

stop() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "[!] Not currently running."
        exit 0
    fi

    ZT_IFACE=$(grep "^ZT_IFACE=" "$STATE_FILE" | cut -d= -f2)
    WAN_IFACE=$(grep "^WAN_IFACE=" "$STATE_FILE" | cut -d= -f2)
    ZT_IP=$(grep "^ZT_IP=" "$STATE_FILE" | cut -d= -f2)

    echo "[-] Stopping exit node..."

    # -- Disable IP forwarding --
    sysctl -w net.ipv4.ip_forward=0 >/dev/null

    # -- Remove iptables NAT rules --
    iptables -t nat -D POSTROUTING -s "$ZT_NET" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$WAN_IFACE" -o "$ZT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    echo "[-] iptables NAT cleared."

    # -- Remove dnsmasq config and restart --
    rm -f "$DNSMASQ_CONF"
    systemctl restart dnsmasq
    echo "[-] dnsmasq config removed."

    rm -f "$STATE_FILE"
    echo "[-] Exit node stopped."
}

status() {
    echo "=== Status ==="
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
        echo "State: running"
    else
        echo "State: stopped"
    fi

    echo ""
    echo "=== IP Forwarding ==="
    sysctl net.ipv4.ip_forward

    echo ""
    echo "=== iptables NAT ==="
    iptables -t nat -L POSTROUTING -n -v | grep -E "MASQUERADE|Chain" || echo "No NAT rules."

    echo ""
    echo "=== dnsmasq ==="
    echo -n "Service: "
    systemctl is-active dnsmasq
    echo -n "Listening on :53: "
    _ZT_IP=$(grep "^ZT_IP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    if [ -n "$_ZT_IP" ]; then
        nc -z -w1 "$_ZT_IP" 53 2>/dev/null && echo "OK" || echo "not listening"
    else
        echo "not running"
    fi

    echo ""
    echo "=== ZeroTier Interface ==="
    _ZT_IFACE=$(zerotier-cli listnetworks 2>/dev/null | grep -oE 'zt[a-z0-9]+' | head -1)
    if [ -n "$_ZT_IFACE" ]; then
        ip addr show "$_ZT_IFACE"
    else
        echo "Interface not found."
    fi

    echo ""
    echo "=== Connectivity ==="
    echo -n "Internet (8.8.8.8): "
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "reachable" || echo "unreachable"
    echo -n "DNS self-test (google.com): "
    _ZT_IP=$(grep "^ZT_IP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    if [ -n "$_ZT_IP" ]; then
        nslookup google.com "$_ZT_IP" >/dev/null 2>&1 && echo "OK" || echo "failed"
    else
        echo "not running"
    fi
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    status)  status ;;
    restart)
        stop
        sleep 2
        start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
