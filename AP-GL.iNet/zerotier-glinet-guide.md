# ZeroTier Exit Node via GL.iNet — Configuration Guide

## Overview

This document describes the full setup for routing all LAN traffic through a ZeroTier exit node (Mac mini) using a GL.iNet router (GL-MT3000, firmware 4.8.1). It covers the network architecture, key issues encountered during debugging, and the final working scripts.

---

## Network Architecture

```
LAN Devices (MacBook, phones, etc.)
    │
    ▼
GL.iNet Router (GL-MT3000)
    │  ZeroTier IP: 10.66.66.100
    │  ZeroTier Interface: ztabc12345
    │
    ▼  [ZeroTier tunnel]
Mac mini (Exit Node)
    │  ZeroTier IP: 10.66.66.2
    │  ZeroTier Interface: feth2351
    │  Runs: zt-exit-node.sh
    │
    ▼
Public Internet
```

### ZeroTier Network

| Node | ZeroTier ID | Virtual IP | Role |
|------|-------------|------------|------|
| Controller / a1b2c3d4e5 | a1b2c3d4e5 | 10.66.66.1 | Self-hosted controller |
| Mac mini | b2c3d4e5f6 | 10.66.66.2 | Exit node |
| GL.iNet | — | 10.66.66.100 | Client router |

---

## Mac mini Exit Node Setup

### macOS-specific Notes

On Apple Silicon Macs, the ZeroTier interface is named `feth<number>` (fake ethernet), not `zt<hash>` as on Linux. Detect it with:

```bash
ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
```

Homebrew is installed at `/opt/homebrew` on Apple Silicon (vs `/usr/local` on Intel). Detect dynamically:

```bash
BREW_PREFIX=$(sudo -u "$REAL_USER" brew --prefix 2>/dev/null)
```

### pf NAT Configuration

macOS uses `pf` for firewalling. The system `/etc/pf.conf` already declares a `zt-exit` anchor — write rules directly into it rather than modifying `pf.conf`:

```bash
sudo tee /etc/pf.anchors/zt-exit << EOF
nat on en0 from 10.66.66.0/24 to any -> (en0)
pass in on feth2351 from 10.66.66.0/24 to any keep state
pass out on en0 from 10.66.66.0/24 to any keep state
EOF

sudo pfctl -e 2>/dev/null || true
sudo pfctl -a zt-exit -f /etc/pf.anchors/zt-exit 2>/dev/null
```

Verify with (not `pfctl -s nat` which shows all rules including noise):

```bash
sudo pfctl -a zt-exit -s nat
```

### dnsmasq for DNS

Install via Homebrew, configure to listen on the ZeroTier IP only:

```
bind-interfaces
listen-address=10.66.66.2
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=feth2351
```

**Important:** Use `sudo brew services start dnsmasq` (with sudo) because binding to port 53 requires root. Running without sudo causes `Address already in use` errors.

To avoid port conflicts on restart, always stop and wait before starting:

```bash
sudo brew services stop dnsmasq
sleep 2
# Wait until port is free
while pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; do
    sleep 1
done
sudo brew services start dnsmasq
```

### Mac mini Script: `zt-exit-node.sh`

Place at `/usr/local/bin/zt-exit-node.sh`. Usage:

```bash
/usr/local/bin/zt-exit-node.sh start
/usr/local/bin/zt-exit-node.sh stop
/usr/local/bin/zt-exit-node.sh status
```

#### macOS Auto-start (launchd)

Create `/Library/LaunchDaemons/com.zerotier.exitnode.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zerotier.exitnode</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/zt-exit-node.sh</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/zt-exit-node.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/zt-exit-node.log</string>
</dict>
</plist>
```

Load it:

```bash
sudo launchctl load /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

---

## GL.iNet Router Setup

### GL.iNet Firmware Internals (4.8.1)

GL.iNet's firmware adds several non-standard iptables chains and routing rules on top of OpenWrt. These interact with custom routing scripts and must be understood before adding rules.

#### Pre-existing ip rule table

```
0:    from all lookup local
100:  from all fwmark 0x64 lookup 100       ← our policy routing rule
800:  from all lookup 9910 suppress_prefixlength 0
6000: from all fwmark 0x8000/0xf000 lookup main
9000: not from all fwmark 0/0xf000 lookup main
9910: not from all fwmark 0/0xf000 blackhole
9920: from all iif br-lan blackhole         ← GL.iNet catch-all blackhole
32766: from all lookup main
32767: from all lookup default
```

Rule `9920` acts as a catch-all blackhole for br-lan traffic that doesn't match earlier rules. Our fwmark rule at priority 100 must fire before this.

#### ROUTE_POLICY chain

GL.iNet's `ROUTE_POLICY` mangle chain intercepts all br-lan traffic before it reaches custom rules. Critically, it contains:

```
RETURN  udp  --  *  *  0.0.0.0/0  0.0.0.0/0  udp dpt:53
```

This causes all DNS queries (UDP port 53) to bypass policy routing and be handled locally by dnsmasq, regardless of any `uci server` settings pointing to an external DNS.

#### ZeroTier firewall zone

GL.iNet creates a `zerotier` firewall zone but does **not** configure forwarding rules between `lan` and `zerotier` by default. Without explicit iptables FORWARD rules, traffic cannot flow between LAN and ZeroTier.

### Issues and Solutions

#### Issue 1: IPv6 bypasses the tunnel

When the router resolves a domain like `google.com`, it may receive an IPv6 AAAA record. Since ZeroTier only carries IPv4, these packets have no valid exit path and are dropped.

**Fix:** Disable IPv6 on the router when the tunnel is active:

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

Restore on stop:

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
```

#### Issue 2: LAN → ZeroTier forwarding blocked

By default, GL.iNet does not permit forwarding between the LAN bridge and the ZeroTier interface.

**Fix:** Add explicit FORWARD rules:

```bash
iptables -I FORWARD -i br-lan -o "$ZT_IFACE" -j ACCEPT
iptables -I FORWARD -i "$ZT_IFACE" -o br-lan -j ACCEPT
```

#### Issue 3: DNS queries not reaching the exit node

GL.iNet's `ROUTE_POLICY` chain returns all UDP/53 traffic before policy routing applies. Setting `uci dhcp.@dnsmasq[0].server` has no effect because dnsmasq's `localservice=1` prevents it from forwarding queries from LAN clients to remote DNS servers.

**Fix:** Use DNAT to redirect LAN DNS queries directly to the exit node, bypassing dnsmasq upstream handling entirely:

```bash
iptables -t nat -I PREROUTING -i br-lan -p udp --dport 53 \
    -j DNAT --to-destination 10.66.66.2:53
iptables -t nat -I PREROUTING -i br-lan -p tcp --dport 53 \
    -j DNAT --to-destination 10.66.66.2:53
```

This works because NAT PREROUTING fires before the mangle ROUTE_POLICY chain intercepts the packet.

#### Issue 4: dnsmasq config directory does not exist

GL.iNet does not create `/etc/dnsmasq.d/` by default. The actual runtime config drop-in directory is `/tmp/dnsmasq.d/`, but even this is not reliably picked up. The DNAT approach in Issue 3 makes this irrelevant.

### GL.iNet Script: `zt-route.sh`

Place at `/root/zt-route.sh`. Usage:

```bash
/root/zt-route.sh start
/root/zt-route.sh stop
/root/zt-route.sh status
/root/zt-route.sh restart
```

#### GL.iNet Auto-start (init.d)

Create `/etc/init.d/zt-route`:

```bash
cat > /etc/init.d/zt-route << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    /root/zt-route.sh start
}

stop() {
    /root/zt-route.sh stop
}
EOF

chmod +x /etc/init.d/zt-route
/etc/init.d/zt-route enable
```

Verify symlinks are created:

```bash
ls -la /etc/rc.d/ | grep zt-route
# S99zt-route -> ../init.d/zt-route  (boot)
# K10zt-route -> ../init.d/zt-route  (shutdown)
```

---

## Operation Order

Always start the exit node before enabling routing on the GL.iNet:

```bash
# 1. Mac mini
/usr/local/bin/zt-exit-node.sh start
/usr/local/bin/zt-exit-node.sh status

# 2. GL.iNet
/root/zt-route.sh start
/root/zt-route.sh status
```

To stop:

```bash
# GL.iNet first
/root/zt-route.sh stop

# Then Mac mini
/usr/local/bin/zt-exit-node.sh stop
```

---

## Verification

From a LAN device connected to GL.iNet:

```bash
# Should return Mac mini's public IP, not GL.iNet's WAN IP
curl -4 ifconfig.me

# DNS should resolve via Mac mini
nslookup google.com
```

From GL.iNet itself (router's own traffic is not marked, so it still uses local routing):

```bash
# This returns GL.iNet's own WAN IP — this is expected
curl -4 ifconfig.me
```

---

## Key Takeaways

| Problem | Root Cause | Fix |
|---------|-----------|-----|
| LAN devices can't reach internet | ZeroTier firewall zone has no forward rules | Add explicit iptables FORWARD rules |
| DNS resolution fails | GL.iNet ROUTE_POLICY chain intercepts UDP/53 before upstream settings apply | Use iptables DNAT to redirect DNS to exit node |
| Domain names resolve to IPv6, then fail | ZeroTier only carries IPv4 | Disable IPv6 via sysctl while tunnel is active |
| macOS ZeroTier interface not `zt*` | Apple Silicon uses `feth<n>` interface naming | Detect via `zerotier-cli listnetworks` with grep |
| dnsmasq port conflict on macOS | Old process still holds port 53 when restarting | Stop, wait for port release, then start |
| `sudo brew services` ownership warning | brew services should not run as root | Use `sudo -u $REAL_USER brew services` for non-privileged services; use `sudo brew services` only for services needing port 53 |
