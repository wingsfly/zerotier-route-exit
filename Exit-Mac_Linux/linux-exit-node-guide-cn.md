# ZeroTier 出口节点配置指南 — Linux

## 概述

本文档介绍如何将 Linux 主机配置为 ZeroTier 出口节点，使网络中的其他节点（如 GL.iNet 路由器或客户端设备）能够将所有互联网流量通过本机的公网 IP 转发。

---

## 前提条件

- Debian/Ubuntu 或兼容的 Linux 发行版
- 已安装 ZeroTier 并加入网络
- Root 或 sudo 权限
- 已分配 ZeroTier 虚拟 IP（如 `10.66.66.x`）
- ZeroTier 网络子网：`10.66.66.0/24`

---

## 网络架构

```
ZeroTier 网络 (10.66.66.0/24)
    │
    ├── GL.iNet 路由器    10.66.66.100
    ├── Mac 客户端        10.66.66.x
    └── Linux 出口节点    10.66.66.x   ← 本机
            │
            ▼（所有流量转发至此）
    Linux WAN 接口（eth0 / ens3 等）
            │
            ▼
    公网互联网
```

---

## 与 macOS 的差异

| 项目 | macOS | Linux |
|------|-------|-------|
| ZeroTier 接口 | `feth*`（Apple Silicon）或 `zt*` | `zt*` |
| NAT 实现 | `pf` anchor | `iptables MASQUERADE` |
| IP 转发参数 | `net.inet.ip.forwarding` | `net.ipv4.ip_forward` |
| 转发持久化 | 每次 start 时设置 | 同时写入 `/etc/sysctl.conf` |
| DNS 管理 | `brew services` | `systemctl` |
| 开机自启 | launchd plist | systemd service |

---

## 核心组件说明

### 1. IP 转发

运行时开启，并持久化到重启后：

```bash
sysctl -w net.ipv4.ip_forward=1

# 写入 sysctl.conf 持久化
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
```

### 2. iptables NAT

```bash
WAN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
ZT_IFACE=$(zerotier-cli listnetworks | grep -oE 'zt[a-z0-9]+' | head -1)

# 对来自 ZeroTier 子网的流量做 NAT
iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$WAN_IFACE" -j MASQUERADE

# 放行转发
iptables -A FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT
iptables -A FORWARD -i "$WAN_IFACE" -o "$ZT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
```

持久化 iptables 规则（重启后仍有效）：

```bash
# Debian/Ubuntu
apt-get install -y iptables-persistent
netfilter-persistent save
```

### 3. DNS（dnsmasq）

安装并配置 dnsmasq，只监听 ZeroTier 接口的 IP：

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

验证：

```bash
systemctl is-active dnsmasq
nc -z -w1 "$ZT_IP" 53 && echo "listening" || echo "not listening"
```

---

## 脚本：`zt-exit-node-linux.sh`

### 安装

```bash
cp zt-exit-node-linux.sh /usr/local/bin/zt-exit-node-linux.sh
chmod +x /usr/local/bin/zt-exit-node-linux.sh
```

### 使用方式

```bash
/usr/local/bin/zt-exit-node-linux.sh start     # 启动出口节点
/usr/local/bin/zt-exit-node-linux.sh stop      # 停止出口节点
/usr/local/bin/zt-exit-node-linux.sh status    # 查看当前状态
/usr/local/bin/zt-exit-node-linux.sh restart   # 重启
```

### `start` 执行流程

1. 检测 ZeroTier 接口和 WAN 接口
2. 从接口读取 ZeroTier IP
3. 通过 `sysctl` 开启 IP 转发，并写入 `/etc/sysctl.conf` 持久化
4. 添加 iptables MASQUERADE NAT 和 FORWARD 规则
5. 写入 dnsmasq 配置，监听 ZeroTier IP
6. 通过 systemctl 重启 dnsmasq 并验证监听状态
7. 将运行状态保存至 `/tmp/zt-exit.state`

### `stop` 执行流程

1. 关闭 IP 转发
2. 删除 iptables NAT 和 FORWARD 规则
3. 删除 dnsmasq 配置并重启服务
4. 删除状态文件

---

## 开机自启（systemd）

创建 `/etc/systemd/system/zt-exit-node.service`：

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

查看状态：

```bash
systemctl status zt-exit-node
journalctl -u zt-exit-node -f
```

---

## 额外前置配置

**ZeroTier 安装并加入网络：**

```bash
# 安装 ZeroTier
curl -s https://install.zerotier.com | sudo bash

# 加入网络
zerotier-cli join a1b2c3d4e5f60789

# 验证（应显示 OK 并有分配的 IP）
zerotier-cli listnetworks
```

授权操作在 Controller 侧完成。

**iptables 持久化（Debian/Ubuntu）：**

脚本在运行时添加 iptables 规则，重启后会失效。有两种持久化方式：

- 安装 `iptables-persistent` 独立持久化
- 或依赖 systemd service 在每次开机时通过 `start` 重新应用规则（推荐，与脚本配合更一致）

**云主机防火墙 / 安全组：**

如果 Linux 主机是云虚拟机（AWS、GCP 等），需在安全组或防火墙中放行：

- UDP 9993 入站 — ZeroTier 隧道流量
- 来自 `10.66.66.0/24` 的流量入站 — ZeroTier 虚拟网络

---

## 验证方法

启动出口节点后，从通过它路由的客户端验证：

```bash
# 应返回本机的公网 IP
curl -4 ifconfig.me

# DNS 应通过本机解析
nslookup google.com 10.66.66.x
```

在 Linux 出口节点本机验证：

```bash
# 查看 iptables NAT 规则
iptables -t nat -L POSTROUTING -n -v

# 确认 dnsmasq 在监听
ss -ulnp | grep :53

# 确认 IP 转发已开启
sysctl net.ipv4.ip_forward
```

---

## 关键问题汇总

| 问题 | 根本原因 | 解决方案 |
|------|---------|---------|
| 重启后 NAT 失效 | iptables 规则默认不持久化 | 安装 `iptables-persistent` 或依赖 systemd service 重新应用 |
| dnsmasq 无法启动 | `systemd-resolved` 占用了 53 端口 | 见下方说明 |
| 找不到 ZeroTier 接口 | ZeroTier 未运行或未加入网络 | 执行 `systemctl start zerotier-one` 和 `zerotier-cli join <nwid>` |
| 云主机流量无法转发 | 安全组阻止了 ZeroTier UDP 9993 | 添加 UDP 9993 入站规则 |

### dnsmasq 与 systemd-resolved 冲突

Ubuntu 18.04 及以上版本，`systemd-resolved` 默认监听 `127.0.0.53:53`，可能与 dnsmasq 冲突。

检查：

```bash
ss -ulnp | grep :53
```

如果 `systemd-resolved` 占用了 53 端口，禁用其 stub listener：

```bash
sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
systemctl restart systemd-resolved
systemctl restart dnsmasq
```
