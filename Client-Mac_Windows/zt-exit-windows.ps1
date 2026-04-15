# zt-exit-windows.ps1
# ZeroTier Exit Node Client Script for Windows
# Must be run as Administrator
#
# WARNING: This script has not been tested in a real environment.
#          Use with caution and verify each step manually on first run.
#
# Usage:
#   .\zt-exit-windows.ps1 enable 10.66.66.2
#   .\zt-exit-windows.ps1 disable
#   .\zt-exit-windows.ps1 status

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$ExitIP
)

$STATE_FILE = "$env:TEMP\zt-exit-state.json"

# ============ Check Administrator ============
function Check-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "x This script must be run as Administrator." -ForegroundColor Red
        Write-Host "  Right-click PowerShell and select 'Run as administrator'."
        exit 1
    }
}

# ============ Get default gateway and interface ============
function Get-DefaultGateway {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
    return $route.NextHop
}

function Get-DefaultInterface {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
    return $route.InterfaceIndex
}

# ============ Get ZeroTier interface ============
function Get-ZeroTierInterface {
    $iface = Get-NetAdapter | Where-Object { $_.Description -like "*ZeroTier*" } | Select-Object -First 1
    if (-not $iface) {
        Write-Host "x ZeroTier network adapter not found." -ForegroundColor Red
        Write-Host "  Make sure ZeroTier is installed and joined to the network."
        exit 1
    }
    return $iface
}

# ============ Disable / Restore IPv6 ============
function Disable-IPv6 {
    Write-Host "  Disabling IPv6 on all adapters..."
    Get-NetAdapter | ForEach-Object {
        Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    }
}

function Enable-IPv6 {
    Write-Host "  Restoring IPv6 on all adapters..."
    Get-NetAdapter | ForEach-Object {
        Enable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    }
}

# ============ Enable exit node ============
function Enable-Exit {
    param([string]$ExitVirtualIP)

    if (Test-Path $STATE_FILE) {
        Write-Host "x An exit node is already active. Run 'disable' first." -ForegroundColor Red
        exit 1
    }

    if (-not $ExitVirtualIP) {
        Write-Host "x Please specify an exit node virtual IP." -ForegroundColor Red
        Write-Host "  Example: .\zt-exit-windows.ps1 enable 10.66.66.2"
        exit 1
    }

    Write-Host "[+] Enabling ZeroTier exit node: $ExitVirtualIP"

    $originalGW = Get-DefaultGateway
    $ifaceIndex = Get-DefaultInterface
    $ztIface = Get-ZeroTierInterface

    Write-Host "  Original gateway : $originalGW"
    Write-Host "  Interface index  : $ifaceIndex"
    Write-Host "  ZeroTier adapter : $($ztIface.Name)"

    # Save state for restore
    $state = @{
        OriginalGW   = $originalGW
        IfaceIndex   = $ifaceIndex
        ExitVirtualIP = $ExitVirtualIP
    }
    $state | ConvertTo-Json | Set-Content $STATE_FILE

    # Protect ZeroTier underlay: resolve the exit node's underlay IP via zerotier-cli
    Write-Host "  Resolving underlay IP for $ExitVirtualIP..."
    $ztPeers = & "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" -j peers 2>$null | ConvertFrom-Json
    $underlayIP = $null
    foreach ($peer in $ztPeers) {
        foreach ($path in $peer.paths) {
            if ($path.active -and $path.address -notmatch ":") {
                # Match by checking virtual IP would require controller API
                # Simplified: protect all active peer underlay IPs
                $ip = $path.address -replace "/.*", ""
                route add $ip mask 255.255.255.255 $originalGW | Out-Null
            }
        }
    }

    # Disable IPv6 to prevent bypass
    Disable-IPv6

    # Remove current default route and add new one via exit node
    Write-Host "  Setting default route via $ExitVirtualIP..."
    route delete 0.0.0.0 mask 0.0.0.0 | Out-Null
    route add 0.0.0.0 mask 0.0.0.0 $ExitVirtualIP metric 1 | Out-Null

    Write-Host "[+] Exit node enabled. All traffic routed through $ExitVirtualIP." -ForegroundColor Green
    Write-Host "    Verify: curl.exe -4 ifconfig.me"
}

# ============ Disable exit node ============
function Disable-Exit {
    if (-not (Test-Path $STATE_FILE)) {
        Write-Host "x No state file found. Is an exit node currently active?" -ForegroundColor Red
        exit 1
    }

    $state = Get-Content $STATE_FILE | ConvertFrom-Json
    $originalGW = $state.OriginalGW

    Write-Host "[-] Restoring default gateway: $originalGW"

    # Restore default route
    route delete 0.0.0.0 mask 0.0.0.0 | Out-Null
    route add 0.0.0.0 mask 0.0.0.0 $originalGW metric 1 | Out-Null

    # Clean up added host routes (best effort)
    Write-Host "  Cleaning up host routes..."
    $ztPeers = & "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" -j peers 2>$null | ConvertFrom-Json
    foreach ($peer in $ztPeers) {
        foreach ($path in $peer.paths) {
            if ($path.active -and $path.address -notmatch ":") {
                $ip = $path.address -replace "/.*", ""
                route delete $ip mask 255.255.255.255 | Out-Null
            }
        }
    }

    # Restore IPv6
    Enable-IPv6

    Remove-Item $STATE_FILE -Force
    Write-Host "[-] Default routing restored." -ForegroundColor Green
}

# ============ Status ============
function Show-Status {
    Write-Host "=== Status ==="
    if (Test-Path $STATE_FILE) {
        $state = Get-Content $STATE_FILE | ConvertFrom-Json
        Write-Host "State      : running"
        Write-Host "Exit node  : $($state.ExitVirtualIP)"
        Write-Host "Orig GW    : $($state.OriginalGW)"
    } else {
        Write-Host "State      : stopped"
    }

    Write-Host ""
    Write-Host "=== Current Default Route ==="
    Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object NextHop, RouteMetric, InterfaceIndex | Format-Table

    Write-Host "=== ZeroTier Adapter ==="
    $ztIface = Get-NetAdapter | Where-Object { $_.Description -like "*ZeroTier*" }
    if ($ztIface) {
        $ztIface | Select-Object Name, Status, MacAddress | Format-Table
        Get-NetIPAddress -InterfaceIndex $ztIface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object IPAddress, PrefixLength | Format-Table
    } else {
        Write-Host "ZeroTier adapter not found."
    }

    Write-Host "=== Connectivity ==="
    Write-Host -NoNewline "Internet (8.8.8.8): "
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
    if ($ping) { Write-Host "reachable" -ForegroundColor Green } else { Write-Host "unreachable" -ForegroundColor Red }
}

# ============ Usage ============
function Show-Usage {
    Write-Host "Usage: .\zt-exit-windows.ps1 <command> [args]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  enable <IP>   Route all traffic through the specified exit node"
    Write-Host "  disable       Restore default routing"
    Write-Host "  status        Show current status"
    Write-Host ""
    Write-Host "Example:"
    Write-Host "  .\zt-exit-windows.ps1 enable 10.66.66.2"
    Write-Host "  .\zt-exit-windows.ps1 disable"
}

# ============ Main ============
Check-Admin

switch ($Command) {
    "enable"  { Enable-Exit -ExitVirtualIP $ExitIP }
    "disable" { Disable-Exit }
    "status"  { Show-Status }
    default   { Show-Usage; exit 1 }
}
