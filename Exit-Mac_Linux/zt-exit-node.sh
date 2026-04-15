#!/bin/bash

ZT_NET="10.66.66.0/24"
# Detect ZeroTier interface - supports both feth (Apple Silicon) and zt (Intel/Linux)
ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
# Detect default WAN interface
WAN_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')

# Get the actual logged-in user (non-root) for brew services
REAL_USER=$(stat -f "%Su" /dev/console)
# Auto-detect Homebrew prefix: /opt/homebrew (Apple Silicon) or /usr/local (Intel)
BREW_PREFIX=$(sudo -u "$REAL_USER" brew --prefix 2>/dev/null)
DNSMASQ_CONF="$BREW_PREFIX/etc/dnsmasq.d/zt-exit.conf"

STATE_FILE="/tmp/zt-exit.state"

start() {
    if [ -f "$STATE_FILE" ]; then
        echo "[!] Already running. Run stop first."
        exit 1
    fi

    echo "[+] Starting Mac mini exit node..."

    if [ -z "$ZT_IFACE" ]; then
        echo "[-] ZeroTier interface not found. Exiting."
        exit 1
    fi
    echo "[+] ZeroTier interface: $ZT_IFACE"
    echo "[+] WAN interface: $WAN_IFACE"

    # -- Enable IP forwarding --
    sudo sysctl -w net.inet.ip.forwarding=1

    # -- NAT via pf --
    # Write rules into the zt-exit anchor (already declared in /etc/pf.conf)
    sudo tee /etc/pf.anchors/zt-exit << EOF
nat on $WAN_IFACE from $ZT_NET to any -> ($WAN_IFACE)
pass in on $ZT_IFACE from $ZT_NET to any keep state
pass out on $WAN_IFACE from $ZT_NET to any keep state
EOF

    sudo pfctl -e 2>/dev/null || true
    sudo pfctl -a zt-exit -f /etc/pf.anchors/zt-exit 2>/dev/null

    if sudo pfctl -a zt-exit -s nat 2>/dev/null | grep -q "$WAN_IFACE"; then
        echo "[+] pf NAT enabled."
    else
        echo "[-] pf NAT failed to load."
        exit 1
    fi

    # -- DNS via dnsmasq --
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "[!] dnsmasq not found. Installing..."
        sudo -u "$REAL_USER" brew install dnsmasq
    fi

    ZT_IP=$(ifconfig "$ZT_IFACE" | awk '/inet /{print $2}')
    if [ -z "$ZT_IP" ]; then
        echo "[-] Could not get ZeroTier IP from interface $ZT_IFACE."
        exit 1
    fi

    # Ensure dnsmasq.d directory exists
    sudo mkdir -p "$BREW_PREFIX/etc/dnsmasq.d"

    # Configure dnsmasq to listen only on the ZeroTier interface IP
    sudo tee "$DNSMASQ_CONF" << EOF
bind-interfaces
listen-address=$ZT_IP
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=$ZT_IFACE
EOF

    # Stop existing dnsmasq and wait for port 53 to be released
    # Must use sudo brew services to bind privileged port 53
    sudo brew services stop dnsmasq 2>/dev/null
    sleep 2
    local wait=0
    while pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; do
        sleep 1
        wait=$((wait + 1))
        if [ $wait -ge 10 ]; then
            echo "[-] Timeout waiting for port 53 to free. Force killing dnsmasq..."
            sudo pkill -x dnsmasq 2>/dev/null
            sleep 1
            break
        fi
    done

    # Start dnsmasq with sudo to allow binding to port 53
    sudo brew services start dnsmasq
    sleep 1

    if pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; then
        echo "[+] dnsmasq started, listening on $ZT_IP:53"
    else
        echo "[-] dnsmasq failed to start. Check configuration."
        exit 1
    fi

    # Save state
    {
        echo "ZT_IFACE=$ZT_IFACE"
        echo "ZT_IP=$ZT_IP"
        echo "WAN_IFACE=$WAN_IFACE"
        echo "STARTED=$(date)"
    } > "$STATE_FILE"

    echo "[+] Done. Mac mini is now acting as ZeroTier exit node."
    echo "[+] ZeroTier IP: $ZT_IP"
}

stop() {
    echo "[-] Stopping exit node..."

    # -- Disable IP forwarding --
    sudo sysctl -w net.inet.ip.forwarding=0

    # -- Clear pf anchor --
    sudo pfctl -a zt-exit -F all 2>/dev/null
    sudo rm -f /etc/pf.anchors/zt-exit
    echo "[-] pf NAT cleared."

    # -- Remove dnsmasq config and stop service --
    sudo rm -f "$DNSMASQ_CONF"
    sudo brew services stop dnsmasq
    echo "[-] dnsmasq stopped."

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
    sysctl net.inet.ip.forwarding

    echo ""
    echo "=== pf NAT Rules ==="
    sudo pfctl -a zt-exit -s nat 2>/dev/null || echo "No NAT rules."

    echo ""
    echo "=== dnsmasq ==="
    echo -n "Process: "
    pgrep -x dnsmasq >/dev/null && echo "running (PID: $(pgrep -x dnsmasq))" || echo "not running"
    echo -n "Listening on :53: "
    _ZT_IP_CHECK=$(grep "^ZT_IP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    if [ -n "$_ZT_IP_CHECK" ]; then
        nc -z -w1 "$_ZT_IP_CHECK" 53 2>/dev/null && echo "OK" || echo "not listening"
    else
        echo "not running"
    fi

    echo ""
    echo "=== ZeroTier Interface ==="
    _ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
    ifconfig "$_ZT_IFACE" 2>/dev/null || echo "Interface not found."

    echo ""
    echo "=== Connectivity ==="
    echo -n "Internet (8.8.8.8): "
    ping -c 1 -W 2000 8.8.8.8 >/dev/null 2>&1 && echo "reachable" || echo "unreachable"
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
