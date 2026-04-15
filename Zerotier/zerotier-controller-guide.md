# ZeroTier Self-Hosted Controller — Configuration Guide

## Overview

This guide covers installing ZeroTier, setting up a self-hosted controller on a Linux VPS, managing network members, and verifying connectivity. Exit node configuration is covered in separate platform-specific documents.

---

## Network Topology

```
Mac A  (10.66.66.3)  ──┐
                          ├── Linux VPS (Controller, 10.66.66.1)
Mac B  (10.66.66.2)  ──┘
GL.iNet (10.66.66.100) ─┘
Windows (10.66.66.x) ───┘
```

| Node | Node ID | Virtual IP | Role |
|------|---------|-----------|------|
| Linux VPS | `a1b2c3d4e5` | `10.66.66.1` | Controller |
| Mac mini | `b2c3d4e5f6` | `10.66.66.2` | Client / Exit Node |
| MacBook | `c3d4e5f6a7` | `10.66.66.3` | Client |
| GL.iNet | `d4e5f6a7b8` | `10.66.66.100` | Client router |

---

## 1. Install ZeroTier

### Linux (Ubuntu/Debian)

```bash
curl -s https://install.zerotier.com | sudo bash
sudo systemctl enable zerotier-one
sudo systemctl start zerotier-one
```

### macOS

```bash
# Option 1: Download installer from official site
# https://www.zerotier.com/download/

# Option 2: Homebrew
brew install --cask zerotier-one
```

### Windows

1. Download the installer from [https://www.zerotier.com/download/](https://www.zerotier.com/download/)
2. Run the installer — a ZeroTier icon will appear in the system tray after completion

### Verify Installation

```bash
# Linux
zerotier-cli info

# macOS (requires sudo)
sudo zerotier-cli info

# Windows (Administrator PowerShell)
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" info
```

Expected output:

```
200 info a1b2c3d4e5 1.16.1 ONLINE
```

---

## 2. Common Startup Issues

### Port already in use

```
zerotier-one: fatal error: cannot bind to local control interface port 9993
```

A ZeroTier process is already running. Check and resolve:

```bash
# Check for existing process
ps aux | grep zerotier

# Check port usage
ss -ulnp | grep 9993

# Kill stale process if needed
pkill zerotier-one
zerotier-one -d

# If managed by systemd, check status directly
systemctl status zerotier-one
```

---

## 3. Set Up Self-Hosted Controller on Linux VPS

> The ZeroTier controller is built into `zerotier-one` — no additional software needed.

### 3.1 Get Node Info and Auth Token

```bash
zerotier-cli info
cat /var/lib/zerotier-one/authtoken.secret
```

Example output:

```
200 info a1b2c3d4e5 1.16.1 ONLINE
b26s7salv8n0697x3ockq8wb
```

> ⚠️ `authtoken.secret` is the credential for the local controller API. Keep it private — never commit it to a git repository.

### 3.2 Create a Virtual Network

The Network ID is composed of the Node ID (10 hex chars) + a custom suffix (6 hex chars). Example: `a1b2c3d4e5` + `f60789` = `a1b2c3d4e5f60789`.

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789 \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dubai-network",
    "private": true,
    "v4AssignMode": {"zt": true},
    "ipAssignmentPools": [
      {"ipRangeStart": "10.66.66.1", "ipRangeEnd": "10.66.66.254"}
    ],
    "routes": [
      {"target": "10.66.66.0/24"}
    ]
  }'
```

A successful response returns JSON — confirm the `"id"` field matches your intended Network ID.

### 3.3 Controller Node Joins Its Own Network

The controller does not auto-join. Do it manually and assign a fixed IP:

```bash
# Join the network
zerotier-cli join a1b2c3d4e5f60789

# Authorize self and assign a fixed IP
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)
NODE=$(zerotier-cli info | awk '{print $3}')

curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/$NODE \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.1"]}'
```

---

## 4. Join the Network from Client Nodes

### Linux / macOS

```bash
# Linux
zerotier-cli join a1b2c3d4e5f60789

# macOS (requires sudo)
sudo zerotier-cli join a1b2c3d4e5f60789
```

### Windows

**Option 1 — System tray (recommended):**

1. Right-click the ZeroTier icon in the system tray
2. Click **Join New Network...**
3. Enter the Network ID: `a1b2c3d4e5f60789`
4. Click Join

**Option 2 — Command line (Administrator PowerShell):**

```powershell
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" join a1b2c3d4e5f60789
```

Get the Node ID to use for authorization:

```powershell
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" info
```

---

## 5. Authorize Nodes from the Controller

### 5.1 List Pending Members

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

curl -s http://localhost:9993/controller/network/a1b2c3d4e5f60789/member \
  -H "X-ZT1-Auth: $AUTH"
```

Example response:

```json
{"c3d4e5f6a7": 1, "e5f6a7b8c9": 1}
```

### 5.2 Authorize a Single Node

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/<nodeId> \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.x"]}'
```

### 5.3 Batch Authorization Example

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

# MacBook
curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/c3d4e5f6a7 \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.3"]}'

# Mac mini
curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/b2c3d4e5f6 \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.2"]}'

# GL.iNet
curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/d4e5f6a7b8 \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.100"]}'
```

---

## 6. View All Authorized Members

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)
NETWORK=a1b2c3d4e5f60789

curl -s http://localhost:9993/controller/network/$NETWORK/member \
  -H "X-ZT1-Auth: $AUTH" | python3 -c "
import sys, json, urllib.request

auth = '$AUTH'
network = '$NETWORK'
members = json.load(sys.stdin)

print('{:<15} {:<20} {:<12}'.format('NODE ID', 'IP ASSIGNMENTS', 'AUTHORIZED'))
print('-' * 47)

for node_id in members:
    req = urllib.request.Request(
        f'http://localhost:9993/controller/network/{network}/member/{node_id}',
        headers={'X-ZT1-Auth': auth}
    )
    with urllib.request.urlopen(req) as r:
        d = json.load(r)
    ips = ', '.join(d.get('ipAssignments', [])) or 'none'
    auth_status = d.get('authorized', False)
    print('{:<15} {:<20} {}'.format(node_id, ips, auth_status))
"
```

Expected output:

```
NODE ID         IP ASSIGNMENTS       AUTHORIZED
-----------------------------------------------
c3d4e5f6a7      10.66.66.3          True
d4e5f6a7b8      10.66.66.100        True
b2c3d4e5f6      10.66.66.2          True
a1b2c3d4e5      10.66.66.1          True
```

---

## 7. Verify Connectivity

Ping any node's virtual IP from another node:

```bash
# Linux / macOS
ping 10.66.66.1    # Controller
ping 10.66.66.2    # Mac mini
ping 10.66.66.3    # MacBook

# Windows
ping 10.66.66.1
```

Check this node's assigned virtual IP:

```bash
# Linux
zerotier-cli listnetworks

# macOS
sudo zerotier-cli listnetworks

# Windows
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" listnetworks
```

Check peer connection status and link type:

```bash
# Linux
zerotier-cli peers

# macOS
sudo zerotier-cli peers
```

Output columns:

| Column | Description |
|--------|-------------|
| `<ztaddr>` | Peer's ZeroTier Node ID |
| `<role>` | `LEAF` = regular node, `PLANET` = ZeroTier root server |
| `<link>` | `DIRECT` = P2P hole-punch succeeded, `RELAY` = traffic is relayed |
| `<lat>` | Latency in ms (`-1` = not measured) |
| `<path>` | Peer's real underlay IP:port |

---

## 8. Optional: Web UI (ztncui)

Managing members via curl is verbose. A lightweight web UI can be deployed via Docker:

```bash
docker run -d \
  --name ztncui \
  --restart always \
  -p 3000:3000 \
  -v /var/lib/zerotier-one:/var/lib/zerotier-one \
  -e ZTNCUI_PASSWD=your_admin_password \
  keynetworks/ztncui
```

Access at `http://<linux-public-ip>:3000` with username `admin` and the password you set.

> ⚠️ Expose port 3000 only to trusted IPs. The UI has full controller access.

---

## Quick Reference

| Operation | Command |
|-----------|---------|
| Check node status | `zerotier-cli info` |
| Join a network | `zerotier-cli join <networkId>` |
| Leave a network | `zerotier-cli leave <networkId>` |
| List joined networks | `zerotier-cli listnetworks` |
| List peers | `zerotier-cli peers` |
| Read auth token (Linux) | `cat /var/lib/zerotier-one/authtoken.secret` |
| Read auth token (macOS) | `cat /Library/Application\ Support/ZeroTier/One/authtoken.secret` |
| List controller members | `curl -s http://localhost:9993/controller/network/<nwid>/member -H "X-ZT1-Auth: $AUTH"` |
| Authorize a member | `curl -X POST .../member/<nodeId> -d '{"authorized": true, ...}'` |

---

## Notes

**Do not use `allowDefault=1`:**

```bash
# DO NOT run this
zerotier-cli set <networkId> allowDefault=1
```

This hands full routing control to ZeroTier and can cause complete loss of network connectivity. All exit node routing in this setup is managed manually via dedicated scripts.

**PLANET nodes in peer list:**

`PLANET` entries (e.g. `cafe04eba9`, `cafefd6717`) are ZeroTier's official global root servers. They are not members of your network — they assist with peer discovery and relay traffic when direct P2P connection fails. They will not appear in the controller member list.

**Controller API is localhost-only:**

The controller API (`http://localhost:9993`) only accepts connections from `127.0.0.1`. To access it from a client machine, use an SSH tunnel:

```bash
ssh -L 19993:127.0.0.1:9993 root@203.0.113.10 -N
curl -s http://127.0.0.1:19993/controller/network/... -H "X-ZT1-Auth: $TOKEN"
```
