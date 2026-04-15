# ZeroTier Exit Node on Linux — Configuration Guide

## Overview

This document covers the full setup for running a Linux machine as a ZeroTier exit node, allowing other nodes in the ZeroTier network (such as a GL.iNet router or client devices) to route all internet traffic through this machine's public IP.

---

## Prerequisites

- Debian/Ubuntu or compatible Linux distribution
- ZeroTier installed and joined to the network
- Root or sudo access
- The machine's ZeroTier virtual IP assigned (e.g. `10.66.66.x`)
- ZeroTier network subnet: `10.66.66.0/24`

---

## Architecture

```
ZeroTier Network (10.66.66.0/24)
    │
    ├── GL.iNet Router    10.66.66.100
    ├── Mac client        10.66.66.x
    └── Linux exit node   10.66.66.x   ← this machine
            │
            ▼ (all traffic forwarded here)
    Linux WAN interface (eth0 / ens3 / etc.)
            │
            ▼
    Public Internet
```

---

## Differences from macOS

| Item | macOS | Linux |
|------|-------|-------|
| ZeroTier interface | `feth*` (Apple Silicon) or `zt*` | `zt*` |
| NAT | `pf` anchor | `iptables MASQUERADE` |
| IP forwarding key | `net.inet.ip.forwarding` | `net.ipv4.ip_forward` |
| Forwarding persistence | Set on each start | Written to `/etc/sysctl.conf` |
| DNS management | `brew services` | `systemctl` |
| Boot auto-start | `launchd` plist | `systemd` service |

---

## Components

### 1. IP Forwarding

Enable at runtime and persist across reboots:

```bash
sysctl -w net.ipv4.ip_forward=1

# Persist in sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
```

### 2. NAT via iptables

```bash
WAN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
ZT_IFACE=$(zerotier-cli listnetworks | grep -oE 'zt[a-z0-9]+' | head -1)

# NAT outbound traffic from ZeroTier subnet
iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$WAN_IFACE" -j MASQUERADE

# Allow forwarding
iptables -A FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT
iptables -A FORWARD -i "$WAN_IFACE" -o "$ZT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
```

To persist iptables rules across reboots:

```bash
# Debian/Ubuntu
apt-get install -y iptables-persistent
netfilter-persistent save
```

### 3. DNS via dnsmasq

Install and configure dnsmasq to listen on the ZeroTier interface IP:

```bash
apt-get install -y dnsmasq

ZT_IP=$(ip addr show "$ZT_IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)

cat > /etc/dnsmasq.d/zt-exit.conf << EOF
bind-interfaces
listen-address=$ZT_IP
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=$ZT_IFACE
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq
```

Verify:

```bash
systemctl is-active dnsmasq
nc -z -w1 "$ZT_IP" 53 && echo "listening" || echo "not listening"
```

---

## Script: `zt-exit-node-linux.sh`

### Installation

```bash
cp zt-exit-node-linux.sh /usr/local/bin/zt-exit-node-linux.sh
chmod +x /usr/local/bin/zt-exit-node-linux.sh
```

### Usage

```bash
/usr/local/bin/zt-exit-node-linux.sh start     # Start exit node
/usr/local/bin/zt-exit-node-linux.sh stop      # Stop exit node
/usr/local/bin/zt-exit-node-linux.sh status    # Show current status
/usr/local/bin/zt-exit-node-linux.sh restart   # Restart
```

### What `start` does

1. Detects ZeroTier interface and WAN interface
2. Reads ZeroTier IP from the interface
3. Enables IP forwarding via `sysctl` and persists to `/etc/sysctl.conf`
4. Adds iptables MASQUERADE NAT and FORWARD rules
5. Writes dnsmasq config listening on the ZeroTier IP
6. Restarts dnsmasq via systemctl and verifies it is listening
7. Saves state to `/tmp/zt-exit.state`

### What `stop` does

1. Disables IP forwarding
2. Removes the iptables NAT and FORWARD rules
3. Removes the dnsmasq config and restarts the service
4. Removes the state file

---

## Auto-start on Boot (systemd)

Create `/etc/systemd/system/zt-exit-node.service`:

```bash
cat > /etc/systemd/system/zt-exit-node.service << 'EOF'
[Unit]
Description=ZeroTier Exit Node
After=network.target zerotier-one.service
Wants=zerotier-one.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zt-exit-node-linux.sh start
ExecStop=/usr/local/bin/zt-exit-node-linux.sh stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zt-exit-node
systemctl start zt-exit-node
```

Check status:

```bash
systemctl status zt-exit-node
journalctl -u zt-exit-node -f
```

---

## Additional Prerequisites

**ZeroTier installed and joined:**

```bash
# Install ZeroTier
curl -s https://install.zerotier.com | sudo bash

# Join the network
zerotier-cli join a1b2c3d4e5f60789

# Verify (should show OK and an assigned IP)
zerotier-cli listnetworks
```

Authorization is granted from the controller.

**iptables persistence (Debian/Ubuntu):**

The script adds iptables rules at runtime. To survive reboots independently of the script:

```bash
apt-get install -y iptables-persistent
netfilter-persistent save
```

Or rely on the systemd service to re-apply rules on every boot via `start`.

**Firewall / cloud security groups:**

If the Linux machine is a cloud VM (AWS, GCP, etc.), ensure the security group or firewall allows:

- UDP 9993 inbound — ZeroTier tunnel traffic
- All traffic from `10.66.66.0/24` inbound — ZeroTier virtual network

---

## Verification

After starting the exit node, verify from a client routed through it:

```bash
# Should show this machine's public IP
curl -4 ifconfig.me

# DNS should resolve via this machine
nslookup google.com 10.66.66.x
```

From the Linux exit node itself:

```bash
# Check iptables NAT
iptables -t nat -L POSTROUTING -n -v

# Check dnsmasq is listening
ss -ulnp | grep :53

# Check forwarding
sysctl net.ipv4.ip_forward
```

---

## Key Issues and Solutions

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| NAT not working after reboot | iptables rules are not persistent by default | Install `iptables-persistent` or rely on systemd service to reapply |
| dnsmasq fails to start | Port 53 may be in use by `systemd-resolved` | See below |
| ZeroTier interface not found | ZeroTier not running or not joined | Run `systemctl start zerotier-one` and `zerotier-cli join <nwid>` |
| Cloud VM traffic not forwarding | Security group blocks ZeroTier UDP 9993 | Add inbound rule for UDP 9993 |

### dnsmasq conflict with systemd-resolved

On Ubuntu 18.04+, `systemd-resolved` listens on `127.0.0.53:53` and may conflict with dnsmasq on port 53.

Check:

```bash
ss -ulnp | grep :53
```

If `systemd-resolved` is using port 53, disable its stub listener:

```bash
# Edit resolved config
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved
systemctl restart dnsmasq
```
