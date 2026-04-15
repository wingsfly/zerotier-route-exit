#!/bin/sh

ZT_GW="10.66.66.2"        # ZeroTier IP of the exit node (Mac mini)
ZT_DNS="10.66.66.2"        # DNS server (same as exit node)
TABLE_ID="100"              # Policy routing table ID
MARK="0x64"                 # Traffic mark for fwmark
STATE_FILE="/tmp/zt-route.state"

# Detect ZeroTier interface (wait up to 30 seconds)
get_zt_iface() {
    for i in $(seq 1 30); do
        IFACE=$(ip link show 2>/dev/null | grep -o 'zt[a-z0-9]*' | head -1)
        if [ -n "$IFACE" ]; then
            echo "$IFACE"
            return 0
        fi
        sleep 1
    done
    return 1
}

start() {
    if [ -f "$STATE_FILE" ]; then
        echo "[!] Already running. Run stop first."
        exit 1
    fi

    echo "[+] Starting ZeroTier global routing..."

    ZT_IFACE=$(get_zt_iface)
    if [ -z "$ZT_IFACE" ]; then
        echo "[-] ZeroTier interface not found. Exiting."
        exit 1
    fi
    echo "[+] ZeroTier interface: $ZT_IFACE"

    # Wait for gateway reachability
    echo "[+] Waiting for ZeroTier gateway $ZT_GW..."
    for i in $(seq 1 20); do
        ping -c 1 -W 1 "$ZT_GW" >/dev/null 2>&1 && break
        sleep 1
    done

    if ! ping -c 1 -W 1 "$ZT_GW" >/dev/null 2>&1; then
        echo "[-] Cannot reach gateway $ZT_GW. Check ZeroTier connection."
        exit 1
    fi
    echo "[+] Gateway $ZT_GW is reachable."

    # -- Disable IPv6 to prevent traffic bypassing the tunnel --
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    echo "[+] IPv6 disabled."

    # -- Policy routing --
    ip route add default via "$ZT_GW" dev "$ZT_IFACE" table "$TABLE_ID" 2>/dev/null
    ip rule add fwmark "$MARK" table "$TABLE_ID" priority 100

    # -- iptables: mark LAN traffic --
    # Exclude ZeroTier self traffic from being marked
    iptables -t mangle -I PREROUTING 1 -i "$ZT_IFACE" -j ACCEPT
    iptables -t mangle -I PREROUTING 2 -p udp --dport 9993 -j ACCEPT
    iptables -t mangle -I PREROUTING 3 -p tcp --dport 9993 -j ACCEPT
    # Mark all LAN traffic
    iptables -t mangle -A PREROUTING -i br-lan -j MARK --set-mark "$MARK"

    # -- Firewall: allow forwarding between LAN and ZeroTier --
    iptables -I FORWARD -i br-lan -o "$ZT_IFACE" -j ACCEPT
    iptables -I FORWARD -i "$ZT_IFACE" -o br-lan -j ACCEPT

    # -- DNS: DNAT LAN DNS requests to exit node --
    # GL.iNet firmware intercepts UDP/53 before dnsmasq upstream settings apply,
    # so we use DNAT to redirect DNS queries directly to the exit node.
    iptables -t nat -I PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to-destination "$ZT_DNS:53"
    iptables -t nat -I PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to-destination "$ZT_DNS:53"
    echo "[+] DNS redirected to $ZT_DNS via DNAT."

    # Save state
    {
        echo "ZT_IFACE=$ZT_IFACE"
        echo "STARTED=$(date)"
    } > "$STATE_FILE"

    echo "[+] Done. All traffic and DNS are routed through $ZT_GW."
}

stop() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "[!] Not currently running."
        exit 0
    fi

    ZT_IFACE=$(grep ZT_IFACE "$STATE_FILE" | cut -d= -f2)
    echo "[-] Stopping ZeroTier global routing..."

    # -- Restore IPv6 --
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    echo "[-] IPv6 restored."

    # -- Remove policy routing --
    ip route del default via "$ZT_GW" dev "$ZT_IFACE" table "$TABLE_ID" 2>/dev/null
    ip rule del fwmark "$MARK" table "$TABLE_ID" priority 100 2>/dev/null

    # -- Remove iptables mangle rules --
    iptables -t mangle -D PREROUTING -i "$ZT_IFACE" -j ACCEPT 2>/dev/null
    iptables -t mangle -D PREROUTING -p udp --dport 9993 -j ACCEPT 2>/dev/null
    iptables -t mangle -D PREROUTING -p tcp --dport 9993 -j ACCEPT 2>/dev/null
    iptables -t mangle -D PREROUTING -i br-lan -j MARK --set-mark "$MARK" 2>/dev/null

    # -- Remove firewall forwarding rules --
    iptables -D FORWARD -i br-lan -o "$ZT_IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$ZT_IFACE" -o br-lan -j ACCEPT 2>/dev/null

    # -- Remove DNS DNAT rules --
    iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to-destination "$ZT_DNS:53" 2>/dev/null
    iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to-destination "$ZT_DNS:53" 2>/dev/null
    echo "[-] DNS restored."

    rm -f "$STATE_FILE"
    echo "[-] Stopped. Traffic and DNS restored to normal."
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
    echo "=== IPv6 ==="
    echo -n "disabled: "
    cat /proc/sys/net/ipv6/conf/all/disable_ipv6

    echo ""
    echo "=== ZeroTier Interface ==="
    _ZT_IFACE=$(ip link show 2>/dev/null | grep -o 'zt[a-z0-9]*' | head -1)
    if [ -n "$_ZT_IFACE" ]; then
        ip addr show "$_ZT_IFACE"
    else
        echo "Interface not found."
    fi

    echo ""
    echo "=== Policy Routing Rules ==="
    ip rule show | grep "$MARK" || echo "No policy routing rules."

    echo ""
    echo "=== Routing Table $TABLE_ID ==="
    ip route show table "$TABLE_ID" 2>/dev/null || echo "Table is empty."

    echo ""
    echo "=== Firewall Forwarding ==="
    iptables -L FORWARD -n | grep "zt" || echo "No ZeroTier forward rules."

    echo ""
    echo "=== DNS DNAT ==="
    iptables -t nat -L PREROUTING -n | grep "53" || echo "No DNS DNAT rules."

    echo ""
    echo "=== Connectivity ==="
    echo -n "ZeroTier gateway ($ZT_GW): "
    ping -c 1 -W 2 "$ZT_GW" >/dev/null 2>&1 && echo "reachable" || echo "unreachable"
    echo -n "Internet (8.8.8.8): "
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "reachable" || echo "unreachable"
    echo -n "DNS resolution (google.com via $ZT_DNS): "
    nslookup google.com "$ZT_DNS" >/dev/null 2>&1 && echo "OK" || echo "failed"
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