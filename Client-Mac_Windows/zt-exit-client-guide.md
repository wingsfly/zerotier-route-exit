# ZeroTier Exit Node — Client Configuration Guide

## Overview

This guide covers how to route all internet traffic through a ZeroTier exit node from individual client devices. This is a device-level configuration, as opposed to the router-level setup (GL.iNet), and must be done separately on each device.

> **Note:** If your device connects through a GL.iNet router that already has `zt-route.sh` running, traffic is already routed transparently — no client-side configuration is needed.

---

## How It Works

```
Client Device (Mac or Windows)
    │
    │  Default route changed to ZeroTier exit node virtual IP
    │
    ▼
ZeroTier Network
    │
    ▼
Exit Node (Mac mini, 10.66.66.2)
    │
    ▼
Public Internet
```

The client script:
1. Saves the current default gateway
2. Adds a host route to protect the ZeroTier underlay connection
3. Disables IPv6 to prevent traffic bypassing the tunnel
4. Sets the default route to the exit node's ZeroTier virtual IP
5. Restores everything on `disable`

---

## Prerequisites

- ZeroTier installed and joined to the network (`10.66.66.0/24`)
- Exit node (Mac mini) running `zt-exit-node.sh start`
- A config file with controller credentials (Mac only)

---

## Mac Client

### Config File

Create `~/.config/zt-exit/config.conf`:

```bash
mkdir -p ~/.config/zt-exit
cat > ~/.config/zt-exit/config.conf << 'EOF'
NETWORK_ID=a1b2c3d4e5f60789
CONTROLLER_SSH_HOST=root@203.0.113.10
CONTROLLER_TOKEN=your_auth_token_here
IPV6_SERVICES=("Wi-Fi")
EOF
```

**Finding your `IPV6_SERVICES`:** Run the `filters` command to list all network services and their IPv6 status:

```bash
./zt-exit-mac.sh filters
```

Copy the first output line directly into your config file.

**Finding your `CONTROLLER_TOKEN`:**

```bash
# On the controller host (Linux)
cat /var/lib/zerotier-one/authtoken.secret

# On the controller host (macOS)
cat /Library/Application\ Support/ZeroTier/One/authtoken.secret
```

**SSH key authentication to controller (recommended):**

The script opens an SSH tunnel to the controller on every `enable` or `list` call. Without key-based auth it will prompt for a password each time. Set up key access once:

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -C "zt-exit-client"

# Copy the public key to the controller
ssh-copy-id root@203.0.113.10

# Verify it works without a password prompt
ssh root@203.0.113.10 echo ok
```

**ZeroTier network membership:**

The client Mac must be joined to the ZeroTier network and authorized by the controller:

```bash
# Join the network
sudo zerotier-cli join a1b2c3d4e5f60789

# Verify (should show OK and an assigned IP)
sudo zerotier-cli listnetworks
```

Authorization is granted from the controller — via the web UI at `my.zerotier.com` or the controller API if self-hosted.

### Installation

```bash
cp zt-exit-mac.sh /usr/local/bin/zt-exit
chmod +x /usr/local/bin/zt-exit
```

### Usage

```bash
# List available exit nodes
zt-exit list

# Enable exit node (route all traffic through 10.66.66.2)
zt-exit enable 10.66.66.2

# Verify (should show Mac mini's public IP)
curl -4 ifconfig.me

# Disable (restore normal routing)
zt-exit disable
```

### How It Works — Mac

The script connects to the ZeroTier controller via SSH tunnel to look up the exit node's underlay (real) IP address. It then:

1. Adds a host route for the underlay IP via the original gateway — this keeps the ZeroTier tunnel itself alive even after the default route changes
2. Removes any conflicting ZeroTier host route for the virtual IP
3. Disables IPv6 on all services listed in `IPV6_SERVICES`
4. Sets the default route to the exit node's ZeroTier virtual IP

On `disable`, everything is restored from the saved state file at `/tmp/zt_original_gw`.

### Troubleshooting — Mac

```bash
# Check current default route
route -n get default

# Check state file
cat /tmp/zt_original_gw

# If routing gets stuck, manually restore
sudo route delete default
sudo route add default <your_original_gateway>
```

---

## Windows Client

> ⚠️ **The Windows script has not been tested in a real environment.**
> The logic and approach are correct, but command behavior may vary across
> Windows versions. Verify each step manually on first use.

### Requirements

- PowerShell 5.1 or later
- ZeroTier One installed (default path: `C:\Program Files (x86)\ZeroTier\One\`)
- Run PowerShell **as Administrator**

**ZeroTier network membership:**

After installing ZeroTier, join the network and ensure the node is authorized:

```powershell
# In an Administrator PowerShell
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" join a1b2c3d4e5f60789

# Verify status (should show OK and an assigned IP)
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" listnetworks
```

Authorization is granted from the controller.

**`zerotier-cli.bat` path:**

The script assumes ZeroTier is installed at `C:\Program Files (x86)\ZeroTier\One\`. If your installation path differs, update the path in the script:

```powershell
# Find actual location
Get-Command zerotier-cli* -ErrorAction SilentlyContinue
# or check
Test-Path "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat"
Test-Path "C:\Program Files\ZeroTier\One\zerotier-cli.bat"
```

### Allow Script Execution

By default, Windows blocks unsigned PowerShell scripts. Run once to allow:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Usage

Open PowerShell as Administrator:

```powershell
# Enable exit node
.\zt-exit-windows.ps1 enable 10.66.66.2

# Verify (should show Mac mini's public IP)
curl.exe -4 ifconfig.me

# Show current status
.\zt-exit-windows.ps1 status

# Disable (restore normal routing)
.\zt-exit-windows.ps1 disable
```

### How It Works — Windows

The script uses Windows `route` commands and PowerShell `Get-NetRoute`/`Get-NetAdapter` to:

1. Save the current default gateway and interface to `%TEMP%\zt-exit-state.json`
2. Add host routes for all active ZeroTier peer underlay IPs via the original gateway
3. Disable IPv6 binding on all adapters via `Disable-NetAdapterBinding`
4. Delete the current default route and add a new one via the exit node virtual IP

On `disable`, the default route is restored and IPv6 re-enabled.

### Manual Fallback — Windows

If the script fails or routing gets stuck, restore manually in an Administrator PowerShell:

```powershell
# Delete the broken default route
route delete 0.0.0.0 mask 0.0.0.0

# Restore your original gateway (e.g. 192.168.1.1)
route add 0.0.0.0 mask 0.0.0.0 192.168.1.1 metric 1

# Re-enable IPv6 on all adapters
Get-NetAdapter | ForEach-Object {
    Enable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
}

# Remove state file
Remove-Item "$env:TEMP\zt-exit-state.json" -Force -ErrorAction SilentlyContinue
```

---

## Verification

After enabling on either platform:

```bash
# Mac
curl -4 ifconfig.me

# Windows
curl.exe -4 ifconfig.me
```

The returned IP should match the Mac mini's public IP, not your local ISP's IP.

---

## Comparison: Router-level vs Device-level

| | GL.iNet (`zt-route.sh`) | Device-level (`zt-exit`) |
|--|------------------------|--------------------------|
| Scope | All LAN devices transparently | Single device only |
| Client config needed | None | Yes, per device |
| Works for Windows | Yes (transparent) | Requires script |
| DNS handled | Yes (DNAT to exit node) | Relies on exit node DNS |
| IPv6 handling | sysctl disable on router | Per-adapter disable |

---

## Key Issues and Solutions

| Issue | Platform | Fix |
|-------|----------|-----|
| Traffic not going through exit node | Mac/Win | Check default route points to ZeroTier virtual IP |
| ZeroTier tunnel drops after route change | Mac/Win | Underlay host route must be added before changing default |
| DNS still resolving via local ISP | Mac/Win | IPv6 must be disabled; exit node dnsmasq must be running |
| PowerShell execution blocked | Windows | Run `Set-ExecutionPolicy RemoteSigned` as admin |
| `route` command requires admin | Windows | Always run PowerShell as Administrator |
