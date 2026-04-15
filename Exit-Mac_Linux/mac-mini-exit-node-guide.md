# ZeroTier Exit Node on macOS — Mac mini Configuration Guide

## Overview

This document covers the full setup for running a Mac mini as a ZeroTier exit node, allowing other nodes in the ZeroTier network (such as a GL.iNet router) to route all internet traffic through the Mac mini's public IP.

---

## Prerequisites

- macOS with ZeroTier installed and joined to the network
- Homebrew installed
- The Mac mini's ZeroTier virtual IP: `10.66.66.2`
- ZeroTier network subnet: `10.66.66.0/24`

---

## Architecture

```
ZeroTier Network (10.66.66.0/24)
    │
    ├── GL.iNet Router    10.66.66.100
    ├── Mac mini (this)   10.66.66.2   ← exit node
    └── Other nodes       10.66.66.x
            │
            ▼ (all traffic forwarded here)
    Mac mini WAN (en0)
            │
            ▼
    Public Internet
```

---

## macOS-specific Considerations

### ZeroTier Interface Naming

On Apple Silicon Macs (M1/M2/M3), ZeroTier uses `feth<number>` interfaces instead of the `zt<hash>` naming used on Linux and Intel Macs. This is because newer macOS versions require a different network extension approach.

Detect the interface dynamically regardless of naming:

```bash
ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
```

Verify with:

```bash
sudo zerotier-cli listnetworks
# 200 listnetworks a1b2c3d4e5f60789 dubai-network ... feth2351 10.66.66.2/24
```

### Homebrew Path

| Architecture | Homebrew Prefix |
|-------------|----------------|
| Apple Silicon (M1/M2/M3) | `/opt/homebrew` |
| Intel | `/usr/local` |

The script detects this automatically:

```bash
BREW_PREFIX=$(sudo -u "$REAL_USER" brew --prefix 2>/dev/null)
```

---

## Components

### 1. IP Forwarding

macOS disables IP forwarding by default. Enable it at runtime:

```bash
sudo sysctl -w net.inet.ip.forwarding=1
```

This is not persistent across reboots — the script handles it on each start.

### 2. NAT via pf

macOS uses `pf` (Packet Filter) for NAT. Rules are loaded into a `zt-exit` anchor declared in `/etc/pf.conf`. **This anchor must exist before running the script.** Check:

```bash
grep "zt-exit" /etc/pf.conf
```

If the lines are missing (e.g. on a fresh machine), add them manually:

```bash
sudo tee -a /etc/pf.conf << 'EOF'

anchor "zt-exit"
load anchor "zt-exit" from "/etc/pf.anchors/zt-exit"
EOF
```

Once the anchor is in place, the script loads rules directly into it without modifying `pf.conf` further:

```bash
sudo tee /etc/pf.anchors/zt-exit << EOF
nat on en0 from 10.66.66.0/24 to any -> (en0)
pass in on feth2351 from 10.66.66.0/24 to any keep state
pass out on en0 from 10.66.66.0/24 to any keep state
EOF

sudo pfctl -e 2>/dev/null || true
sudo pfctl -a zt-exit -f /etc/pf.anchors/zt-exit 2>/dev/null
```

Verify the rules are loaded (use `-a zt-exit` to target the anchor specifically):

```bash
sudo pfctl -a zt-exit -s nat
sudo pfctl -a zt-exit -s rules
```

**Why use an anchor?** Loading rules directly via `-f /etc/pf.conf` flushes all system rules including those added by other services (VPN, sharing, etc.). Writing to an anchor is isolated and safe.

### 3. DNS via dnsmasq

dnsmasq is installed via Homebrew and configured to listen only on the ZeroTier IP, forwarding queries upstream to 8.8.8.8 and 1.1.1.1.

Config file location: `$BREW_PREFIX/etc/dnsmasq.d/zt-exit.conf`

```
bind-interfaces
listen-address=10.66.66.2
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=feth2351
```

**Critical: port 53 requires root.** dnsmasq must be started with `sudo brew services start dnsmasq`. Running as a regular user fails to bind port 53:

```bash
sudo brew services start dnsmasq    # correct
brew services start dnsmasq         # fails silently on port 53
```

**Port conflict on restart.** When restarting dnsmasq, the old process may still hold port 53 for a few seconds. The script stops dnsmasq, waits for the port to be released, then starts fresh:

```bash
sudo brew services stop dnsmasq
sleep 2
# Wait until port is free
while pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; do
    sleep 1
done
sudo brew services start dnsmasq
```

Port availability is checked with `nc -z -w1` instead of `lsof -i :53` — `lsof` on macOS can take 10–30 seconds, while `nc` returns in milliseconds.

---

## Script: `zt-exit-node.sh`

### Installation

```bash
sudo cp zt-exit-node.sh /usr/local/bin/zt-exit-node.sh
sudo chmod +x /usr/local/bin/zt-exit-node.sh
```

### Usage

```bash
/usr/local/bin/zt-exit-node.sh start     # Start exit node
/usr/local/bin/zt-exit-node.sh stop      # Stop exit node
/usr/local/bin/zt-exit-node.sh status    # Show current status
/usr/local/bin/zt-exit-node.sh restart   # Restart
```

### What `start` does

1. Detects ZeroTier interface and WAN interface
2. Enables IP forwarding via `sysctl`
3. Writes and loads pf NAT rules into the `zt-exit` anchor
4. Writes dnsmasq config listening on the ZeroTier IP
5. Stops any existing dnsmasq, waits for port release, starts fresh with sudo
6. Verifies dnsmasq is listening on port 53
7. Saves state to `/tmp/zt-exit.state`

### What `stop` does

1. Disables IP forwarding
2. Flushes the `zt-exit` pf anchor and removes the rules file
3. Removes dnsmasq config and stops the service
4. Removes the state file

---

## Auto-start on Boot (launchd)

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

Load and enable:

```bash
sudo launchctl load /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

To unload:

```bash
sudo launchctl unload /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

Check logs:

```bash
tail -f /var/log/zt-exit-node.log
```

---

## macOS Application Firewall

macOS has an application-level firewall separate from pf. If enabled, it prompts you to allow or deny dnsmasq from accepting incoming connections the first time it runs.

Check the current state:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

If enabled, click **Allow** when macOS prompts for dnsmasq. If the prompt was missed or denied, add it manually:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \
    $(brew --prefix)/sbin/dnsmasq
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp \
    $(brew --prefix)/sbin/dnsmasq
```

---

## Verification

After starting the exit node on Mac mini, verify from a client routed through it:

```bash
# Should show Mac mini's public IP
curl -4 ifconfig.me

# DNS should resolve via Mac mini
nslookup google.com 10.66.66.2
```

From the Mac mini itself:

```bash
# Check pf NAT rules
sudo pfctl -a zt-exit -s nat

# Check dnsmasq is listening on ZeroTier IP
nc -zv 10.66.66.2 53

# Check forwarding is enabled
sysctl net.inet.ip.forwarding
```

---

## Key Issues and Solutions

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| ZeroTier interface is `feth*` not `zt*` | Apple Silicon uses a different network extension | Detect via `zerotier-cli listnetworks` with regex for both patterns |
| pf rules flush system services | `-f /etc/pf.conf` replaces all rules | Write to `zt-exit` anchor instead — isolated and non-destructive |
| dnsmasq fails to bind port 53 | Port 53 is privileged, requires root | Always use `sudo brew services start dnsmasq` |
| `Address already in use` on restart | Old dnsmasq process still holds port 53 | Stop, wait for port release with `nc -z -w1`, then start |
| `lsof -i :53` is too slow | macOS `lsof` performs exhaustive fd scan | Replace with `nc -z -w1` + `pgrep` — millisecond response |
| `sudo brew services` ownership warning | brew modifies paths when run as root | Use `sudo brew services` only for dnsmasq (needs port 53); use `sudo -u $REAL_USER brew services` for other services |
