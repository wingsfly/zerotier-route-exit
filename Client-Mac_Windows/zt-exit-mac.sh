#!/bin/bash

# ============ Config ============
DEFAULT_CONFIG="$HOME/.config/zt-exit/config.conf"

# ============ Parse arguments ============
CONFIG_FILE=$DEFAULT_CONFIG
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

# ============ Load config file ============
load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "✗ Config file not found: $CONFIG_FILE"
    echo ""
    echo "  Create one with:"
    echo ""
    echo "  mkdir -p $(dirname $DEFAULT_CONFIG)"
    echo "  cat > $DEFAULT_CONFIG << 'EOF'"
    echo "  NETWORK_ID=a1b2c3d4e5f60789"
    echo "  CONTROLLER_SSH_HOST=root@203.0.113.10"
    echo "  CONTROLLER_TOKEN=your_auth_token"
    echo "  IPV6_SERVICES=(\"Wi-Fi\")"
    echo "  EOF"
    exit 1
  fi

  source "$CONFIG_FILE"

  for var in NETWORK_ID CONTROLLER_SSH_HOST CONTROLLER_TOKEN; do
    if [ -z "${!var}" ]; then
      echo "✗ Missing required config key: $var"
      exit 1
    fi
  done

  CONTROLLER_URL="http://127.0.0.1:19993"

  if [ -z "${IPV6_SERVICES+x}" ]; then
    IPV6_SERVICES=("Wi-Fi")
  fi
}

# ============ SSH tunnel to controller ============
TUNNEL_PORT=19993
TUNNEL_PID_FILE=/tmp/zt_ssh_tunnel.pid

setup_controller_tunnel() {
  if [ -f $TUNNEL_PID_FILE ] && kill -0 $(cat $TUNNEL_PID_FILE) 2>/dev/null; then
    return 0
  fi

  echo "  Setting up SSH tunnel to controller..."
  ssh -f -N \
    -L $TUNNEL_PORT:127.0.0.1:9993 \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    -o ExitOnForwardFailure=yes \
    $CONTROLLER_SSH_HOST

  pgrep -f "L $TUNNEL_PORT:127.0.0.1:9993" > $TUNNEL_PID_FILE
  sleep 1
  echo "  SSH tunnel established."
}

teardown_controller_tunnel() {
  if [ -f $TUNNEL_PID_FILE ]; then
    kill $(cat $TUNNEL_PID_FILE) 2>/dev/null || true
    rm $TUNNEL_PID_FILE
    echo "  SSH tunnel closed."
  fi
}

# ============ Functions ============
usage() {
  echo "Usage: $0 [-c <config_file>] <command> [args]"
  echo ""
  echo "Commands:"
  echo "  list              List all available exit nodes"
  echo "  enable <IP>       Route all traffic through the specified exit node"
  echo "  disable           Restore default routing"
  echo "  filters           List network services and IPv6 status (for config)"
  echo ""
  echo "Options:"
  echo "  -c, --config <file>  Specify config file (default: $DEFAULT_CONFIG)"
}

list_services() {
  echo "# Copy the first line below into your config file as IPV6_SERVICES:"
  echo ""

  services_with_ipv6=()
  while IFS= read -r svc; do
    name="${svc#\* }"
    ipv6=$(networksetup -getinfo "$name" 2>/dev/null | grep "IPv6:" | awk '{print $2}')
    if [ "$ipv6" = "Automatic" ] || [ "$ipv6" = "Manual" ]; then
      services_with_ipv6+=("\"$name\"")
    fi
  done < <(networksetup -listallnetworkservices | tail -n +2)

  printf "IPV6_SERVICES=("
  for i in "${!services_with_ipv6[@]}"; do
    if [ $i -gt 0 ]; then printf " "; fi
    printf "%s" "${services_with_ipv6[$i]}"
  done
  printf ")\n"

  echo ""
  echo "# All network services:"
  printf "  %-35s %-10s %s\n" "Service" "Interface" "IPv6"
  echo "  $(printf '%0.s-' {1..60})"

  networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r svc; do
    name="${svc#\* }"
    disabled=""
    [[ "$svc" == \** ]] && disabled=" (disabled)"

    iface=$(networksetup -listnetworkserviceorder 2>/dev/null | \
      grep -A1 "$name" | grep "Device:" | \
      sed 's/.*Device: \([^,)]*\).*/\1/' | tr -d ' ')

    ipv6=$(networksetup -getinfo "$name" 2>/dev/null | \
      grep "IPv6:" | awk '{print $2}')

    printf "  %-35s %-10s %s%s\n" "$name" "$iface" "$ipv6" "$disabled"
  done

  echo ""
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" 2>/dev/null
    if [ -n "${IPV6_SERVICES+x}" ]; then
      echo "# Current IPV6_SERVICES in config:"
      for svc in "${IPV6_SERVICES[@]}"; do
        echo "  - $svc"
      done
    fi
  fi
}

get_virtual_to_underlay() {
  local target_virtual=$1

  sudo zerotier-cli -j peers | python3 -c "
import json, sys, urllib.request

target = '$target_virtual'
peers = json.load(sys.stdin)

node_underlay = {}
for p in peers:
    node_id = p.get('address', '')
    for path in p.get('paths', []):
        addr = path.get('address', '')
        if path.get('active') and ':' not in addr:
            node_underlay[node_id] = addr.split('/')[0]
            break

auth = '$CONTROLLER_TOKEN'
base_url = '$CONTROLLER_URL'

try:
    req = urllib.request.Request(
        f'{base_url}/controller/network/$NETWORK_ID/member',
        headers={'X-ZT1-Auth': auth}
    )
    members = json.loads(urllib.request.urlopen(req).read())
    for node_id in members:
        req2 = urllib.request.Request(
            f'{base_url}/controller/network/$NETWORK_ID/member/{node_id}',
            headers={'X-ZT1-Auth': auth}
        )
        member = json.loads(urllib.request.urlopen(req2).read())
        for ip in member.get('ipAssignments', []):
            if ip == target:
                underlay = node_underlay.get(node_id, '')
                if underlay:
                    print(underlay)
                    sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e) + '\n')
sys.exit(1)
" 2>/dev/null
}

list_nodes() {
  echo "Network: $NETWORK_ID"
  echo "Controller: $CONTROLLER_SSH_HOST"
  echo ""

  sudo zerotier-cli -j peers | python3 -c "
import json, sys, urllib.request

peers = json.load(sys.stdin)
auth = '$CONTROLLER_TOKEN'
base_url = '$CONTROLLER_URL'

node_virtual = {}
try:
    req = urllib.request.Request(
        f'{base_url}/controller/network/$NETWORK_ID/member',
        headers={'X-ZT1-Auth': auth}
    )
    members = json.loads(urllib.request.urlopen(req).read())
    for node_id in members:
        req2 = urllib.request.Request(
            f'{base_url}/controller/network/$NETWORK_ID/member/{node_id}',
            headers={'X-ZT1-Auth': auth}
        )
        member = json.loads(urllib.request.urlopen(req2).read())
        ips = member.get('ipAssignments', [])
        authorized = member.get('authorized', False)
        if ips:
            node_virtual[node_id] = (ips[0], authorized)
except Exception as e:
    sys.stderr.write('Controller API error: ' + str(e) + '\n')

print(f'  {\"Node ID\":<14} {\"Virtual IP\":<16} {\"Latency(ms)\":<12} {\"Link\":<8} {\"Auth\":<6} {\"Underlay IP\"}')
print('  ' + '-' * 75)

for p in peers:
    if p.get('role') != 'LEAF':
        continue
    node_id = p.get('address', '')
    latency = p.get('latency', -1)
    online = any(path.get('active') for path in p.get('paths', []))
    link = 'DIRECT' if online else 'RELAY'
    status = 'o' if online else 'x'

    underlay = ''
    for path in p.get('paths', []):
        addr = path.get('address', '')
        if path.get('active') and ':' not in addr:
            underlay = addr.split('/')[0]
            break

    virtual_ip, authorized = node_virtual.get(node_id, ('(unassigned)', False))
    auth_str = 'yes' if authorized else 'no'
    print(f'  {status} {node_id:<12} {virtual_ip:<16} {latency:<12} {link:<8} {auth_str:<6} {underlay}')
"
}

disable_ipv6_all() {
  for svc in "${IPV6_SERVICES[@]}"; do
    sudo networksetup -setv6off "$svc" 2>/dev/null || true
  done
}

restore_ipv6_all() {
  for svc in "${IPV6_SERVICES[@]}"; do
    sudo networksetup -setv6automatic "$svc" 2>/dev/null || true
  done
}

enable_exit() {
  local exit_ip=$1

  if [ -f /tmp/zt_original_gw ]; then
    echo "✗ An exit node is already active. Run 'disable' first."
    exit 1
  fi

  setup_controller_tunnel

  echo "  Resolving underlay IP for $exit_ip..."
  local underlay_ip=$(get_virtual_to_underlay $exit_ip)
  teardown_controller_tunnel

  if [ -z "$underlay_ip" ]; then
    echo "✗ Could not resolve underlay IP for $exit_ip"
    echo "  Run '$0 list' to confirm the node is online and authorized."
    exit 1
  fi

  echo "  Underlay IP: $underlay_ip"

  ORIGINAL_GW=$(route -n get default | grep gateway | awk '{print $2}')
  echo $ORIGINAL_GW > /tmp/zt_original_gw
  echo $underlay_ip >> /tmp/zt_original_gw
  echo $exit_ip >> /tmp/zt_original_gw
  echo "  Original gateway: $ORIGINAL_GW"

  # Protect ZeroTier underlay route so the tunnel itself stays up
  sudo route add -host $underlay_ip $ORIGINAL_GW 2>/dev/null || true

  # Remove any stale ZeroTier host route that may conflict
  echo "  Cleaning up ZeroTier host route..."
  sudo route delete -host $exit_ip 2>/dev/null || true

  # Disable IPv6 to prevent traffic bypassing the tunnel
  echo "  Disabling IPv6..."
  disable_ipv6_all

  # Set default route to exit node
  sudo route delete default 2>/dev/null
  sudo route add default $exit_ip

  echo "✓ Exit node enabled. All traffic routed through $exit_ip."
  echo "  Verify: curl -4 ifconfig.me"
}

disable_exit() {
  if [ ! -f /tmp/zt_original_gw ]; then
    echo "✗ No state file found. Is an exit node currently active?"
    exit 1
  fi

  ORIGINAL_GW=$(sed -n '1p' /tmp/zt_original_gw)
  UNDERLAY_IP=$(sed -n '2p' /tmp/zt_original_gw)

  echo "  Restoring default gateway: $ORIGINAL_GW"
  sudo route delete default 2>/dev/null
  sudo route add default $ORIGINAL_GW
  sudo route delete -host $UNDERLAY_IP 2>/dev/null || true

  echo "  Restoring IPv6..."
  restore_ipv6_all

  rm /tmp/zt_original_gw
  echo "✓ Default routing restored."
}

# ============ Main ============
case "$1" in
  filters)
    list_services
    ;;
  list)
    load_config
    setup_controller_tunnel
    list_nodes
    teardown_controller_tunnel
    ;;
  enable)
    load_config
    if [ -z "$2" ]; then
      echo "✗ Please specify a virtual IP. Example: $0 enable 10.66.66.2"
      echo "  Run '$0 list' to see available nodes."
      exit 1
    fi
    enable_exit $2
    ;;
  disable)
    load_config
    disable_exit
    ;;
  *)
    usage
    exit 1
    ;;
esac
