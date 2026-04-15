> 中文版本: [README.md](README.md)

# ZeroTier Multi-Region Network and Exit Routing Overview

This project helps you build an extensible ZeroTier private network and use internet egress in two ways:

- Method A (device-level): manually switch exit nodes on each client (Mac / Windows)
- Method B (network-level): connect to a designated WiFi AP (GL.iNet) and route through a fixed exit automatically

This document is an end-to-end roadmap from zero to production. It links to the detailed docs for each step without duplicating low-level commands.

---

## 1. Target Architecture and Roles

Recommended minimum roles:

- Controller (recommended on Linux VPS): network control and member authorization
- Exit Node(s) (one or more, by region): NAT + DNS + internet egress
- Clients (Mac / Windows / phones, etc.): consume the egress
- WiFi AP (optional, GL.iNet): all devices on this AP use a designated exit automatically

References:

- Controller (CN): [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
- Controller (EN): [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)

---

## 2. Recommended Execution Order

1. Install ZeroTier (controller + all nodes)
2. Create the network on the controller and define subnet/routes
3. Join all nodes and authorize them on the controller
4. Deploy one or more exit nodes (macOS or Linux)
5. Choose your access model:
   - 5A. Client-side manual exit switching
   - 5B. GL.iNet WiFi AP with fixed exit routing
6. Run connectivity and public-IP verification

---

## 3. From Scratch: Step-by-Step Entry Points

### Step 1: Install ZeroTier

- Entry point (Linux / macOS / Windows install):
  [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
  section "**1. Install ZeroTier**"

### Step 2: Create the Network (Controller)

- Entry point:
  [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
  section "**3. Set Up Self-Hosted Controller on Linux VPS**"

### Step 3: Node Join + Authorization

- Node join:
  [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
  section "**4. Join the Network from Client Nodes**"
- Controller authorization:
  [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
  section "**5. Authorize Nodes from the Controller**"

### Step 4: Configure Exit Nodes (repeat per region)

Repeat this step for each additional region exit.

- macOS exit node (recommended Mac mini):
  [Exit-Mac_Linux/mac-mini-exit-node-guide.md](Exit-Mac_Linux/mac-mini-exit-node-guide.md)
- Linux exit node:
  [Exit-Mac_Linux/linux-exit-node-guide.md](Exit-Mac_Linux/linux-exit-node-guide.md)

Supporting scripts:

- macOS: [`Exit-Mac_Linux/zt-exit-node.sh`](Exit-Mac_Linux/zt-exit-node.sh)
- Linux: [`Exit-Mac_Linux/zt-exit-node-linux.sh`](Exit-Mac_Linux/zt-exit-node-linux.sh)

---

## 4. Method A: Manual Exit Switching on Clients

Use case: switch one device to a target regional exit on demand, without affecting other devices.

Docs:

- Chinese: [Client-Mac_Windows/zt-exit-client-guide-cn.md](Client-Mac_Windows/zt-exit-client-guide-cn.md)
- English: [Client-Mac_Windows/zt-exit-client-guide.md](Client-Mac_Windows/zt-exit-client-guide.md)

Scripts:

- Mac: [`Client-Mac_Windows/zt-exit-mac.sh`](Client-Mac_Windows/zt-exit-mac.sh)
- Windows: [`Client-Mac_Windows/zt-exit-windows.ps1`](Client-Mac_Windows/zt-exit-windows.ps1)

Suggested flow:

1. Make sure node authorization is completed on the controller
2. Run `list` on client to view available exits
3. Run `enable <exit_virtual_ip>` to switch egress
4. Run `disable` when done to restore default routing

---

## 5. Method B: WiFi AP Access with Fixed Exit Routing

Use case: phones/tablets/guest devices that should route through a specific exit by simply joining WiFi.

Docs:

- Chinese: [AP-GL.iNet/zerotier-glinet-guide-cn.md](AP-GL.iNet/zerotier-glinet-guide-cn.md)
- English: [AP-GL.iNet/zerotier-glinet-guide.md](AP-GL.iNet/zerotier-glinet-guide.md)

Scripts:

- Routing policy script: [`AP-GL.iNet/zt-route.sh`](AP-GL.iNet/zt-route.sh)
- init.d startup script: [`AP-GL.iNet/init.d/zt-route`](AP-GL.iNet/init.d/zt-route)

Key order:

1. Start the exit node first (Mac mini / Linux)
2. Start `zt-route.sh` on GL.iNet
3. Connect clients to the AP (no per-device route changes needed)

---

## 6. Multi-Region Expansion (Minimal Rules)

If you need multiple exits (for example Tokyo / Singapore / Frankfurt):

1. Prepare one exit node per region
2. Join all exit nodes to the same ZeroTier network and authorize them
3. Assign fixed virtual IPs for each exit node
4. Let clients switch by target exit IP
5. If using AP mode, bind each AP/site to a fixed exit IP

Implementation details are in sections 4 and 5 above.

---

## 7. Go-Live Checklist

1. `listnetworks` shows `OK` on all nodes
2. Controller can see and authorize all members
3. `start/status` works on each exit node
4. Client public IP matches target region after `enable`
5. Client public IP returns to local uplink after `disable`
6. Devices behind AP show the expected fixed-exit public IP

---

## 8. Documentation Index

- Controller:
  - [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  - [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
- Exit Node:
  - [Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md](Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md)
  - [Exit-Mac_Linux/mac-mini-exit-node-guide.md](Exit-Mac_Linux/mac-mini-exit-node-guide.md)
  - [Exit-Mac_Linux/linux-exit-node-guide-cn.md](Exit-Mac_Linux/linux-exit-node-guide-cn.md)
  - [Exit-Mac_Linux/linux-exit-node-guide.md](Exit-Mac_Linux/linux-exit-node-guide.md)
- Client:
  - [Client-Mac_Windows/zt-exit-client-guide-cn.md](Client-Mac_Windows/zt-exit-client-guide-cn.md)
  - [Client-Mac_Windows/zt-exit-client-guide.md](Client-Mac_Windows/zt-exit-client-guide.md)
- GL.iNet AP:
  - [AP-GL.iNet/zerotier-glinet-guide-cn.md](AP-GL.iNet/zerotier-glinet-guide-cn.md)
  - [AP-GL.iNet/zerotier-glinet-guide.md](AP-GL.iNet/zerotier-glinet-guide.md)
