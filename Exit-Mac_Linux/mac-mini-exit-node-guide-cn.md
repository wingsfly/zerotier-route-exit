# ZeroTier 出口节点配置指南 — Mac mini

## 概述

本文档介绍如何将 Mac mini 配置为 ZeroTier 网络的出口节点，使网络中的其他节点（如 GL.iNet 路由器）能够将所有互联网流量通过 Mac mini 的公网 IP 转发。

---

## 前提条件

- macOS 已安装 ZeroTier 并加入网络
- 已安装 Homebrew
- Mac mini 的 ZeroTier 虚拟 IP：`10.66.66.2`
- ZeroTier 网络子网：`10.66.66.0/24`

---

## 网络架构

```
ZeroTier 网络 (10.66.66.0/24)
    │
    ├── GL.iNet 路由器    10.66.66.100
    ├── Mac mini（本机）  10.66.66.2   ← 出口节点
    └── 其他节点          10.66.66.x
            │
            ▼（所有流量转发至此）
    Mac mini WAN 接口 (en0)
            │
            ▼
    公网互联网
```

---

## macOS 特殊说明

### ZeroTier 接口命名

Apple Silicon Mac（M1/M2/M3）上，ZeroTier 接口以 `feth<数字>` 命名，而非 Linux 和 Intel Mac 上的 `zt<hash>`。这是因为新版 macOS 要求使用不同的网络扩展机制。

动态检测接口名（兼容两种命名）：

```bash
ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
```

验证：

```bash
sudo zerotier-cli listnetworks
# 200 listnetworks a1b2c3d4e5f60789 dubai-network ... feth2351 10.66.66.2/24
```

### Homebrew 路径

| 架构 | Homebrew 路径 |
|------|--------------|
| Apple Silicon (M1/M2/M3) | `/opt/homebrew` |
| Intel | `/usr/local` |

脚本自动检测：

```bash
BREW_PREFIX=$(sudo -u "$REAL_USER" brew --prefix 2>/dev/null)
```

---

## 核心组件说明

### 1. IP 转发

macOS 默认禁用 IP 转发，需在运行时开启：

```bash
sudo sysctl -w net.inet.ip.forwarding=1
```

该设置重启后失效，脚本每次 start 时会自动重新设置。

### 2. pf NAT

macOS 使用 `pf`（Packet Filter）实现 NAT。规则写入 `/etc/pf.conf` 中声明的 `zt-exit` anchor。**运行脚本前必须确认该 anchor 已存在。** 检查方法：

```bash
grep "zt-exit" /etc/pf.conf
```

如果没有（例如在新机器上部署），需要手动添加：

```bash
sudo tee -a /etc/pf.conf << 'EOF'

anchor "zt-exit"
load anchor "zt-exit" from "/etc/pf.anchors/zt-exit"
EOF
```

anchor 就位后，脚本直接向其写入规则，不再修改 `pf.conf`：

```bash
sudo tee /etc/pf.anchors/zt-exit << EOF
nat on en0 from 10.66.66.0/24 to any -> (en0)
pass in on feth2351 from 10.66.66.0/24 to any keep state
pass out on en0 from 10.66.66.0/24 to any keep state
EOF

sudo pfctl -e 2>/dev/null || true
sudo pfctl -a zt-exit -f /etc/pf.anchors/zt-exit 2>/dev/null
```

验证规则是否加载（使用 `-a zt-exit` 指定 anchor）：

```bash
sudo pfctl -a zt-exit -s nat
sudo pfctl -a zt-exit -s rules
```

**为什么用 anchor？** 直接用 `-f /etc/pf.conf` 加载规则会清除所有系统规则，包括 VPN、共享等服务添加的规则。写入 anchor 是隔离的，不影响其他规则。

### 3. DNS（dnsmasq）

通过 Homebrew 安装 dnsmasq，配置只监听 ZeroTier 接口的 IP，将 DNS 查询转发至 8.8.8.8 和 1.1.1.1。

配置文件路径：`$BREW_PREFIX/etc/dnsmasq.d/zt-exit.conf`

```
bind-interfaces
listen-address=10.66.66.2
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=feth2351
```

**重要：53 端口需要 root 权限。** dnsmasq 必须通过 `sudo brew services start dnsmasq` 启动，以普通用户启动无法绑定 53 端口：

```bash
sudo brew services start dnsmasq    # 正确
brew services start dnsmasq         # 绑定 53 端口失败
```

**重启时的端口冲突问题。** 重启 dnsmasq 时，旧进程可能仍占用 53 端口数秒。脚本会先停止服务，等待端口释放后再启动：

```bash
sudo brew services stop dnsmasq
sleep 2
# 等待端口释放
while pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; do
    sleep 1
done
sudo brew services start dnsmasq
```

端口检测使用 `nc -z -w1` 而非 `lsof -i :53`——macOS 上 `lsof` 需要 10–30 秒才有返回，`nc` 毫秒级完成。

---

## 脚本：`zt-exit-node.sh`

### 安装

```bash
sudo cp zt-exit-node.sh /usr/local/bin/zt-exit-node.sh
sudo chmod +x /usr/local/bin/zt-exit-node.sh
```

### 使用方式

```bash
/usr/local/bin/zt-exit-node.sh start     # 启动出口节点
/usr/local/bin/zt-exit-node.sh stop      # 停止出口节点
/usr/local/bin/zt-exit-node.sh status    # 查看当前状态
/usr/local/bin/zt-exit-node.sh restart   # 重启
```

### `start` 执行流程

1. 检测 ZeroTier 接口和 WAN 接口
2. 通过 `sysctl` 开启 IP 转发
3. 将 pf NAT 规则写入 `zt-exit` anchor 并加载
4. 写入 dnsmasq 配置，监听 ZeroTier IP
5. 停止旧 dnsmasq 进程，等待端口释放，以 sudo 重新启动
6. 验证 dnsmasq 是否成功监听 53 端口
7. 将运行状态保存至 `/tmp/zt-exit.state`

### `stop` 执行流程

1. 关闭 IP 转发
2. 清空 `zt-exit` pf anchor，删除规则文件
3. 删除 dnsmasq 配置，停止服务
4. 删除状态文件

---

## 开机自启（launchd）

创建 `/Library/LaunchDaemons/com.zerotier.exitnode.plist`：

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

加载并启用：

```bash
sudo launchctl load /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

卸载：

```bash
sudo launchctl unload /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

查看日志：

```bash
tail -f /var/log/zt-exit-node.log
```

---

## macOS 应用防火墙

macOS 有一个独立于 pf 的应用层防火墙。如果已启用，首次运行 dnsmasq 时系统会弹窗询问是否允许接受入站连接。

检查防火墙状态：

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

如果防火墙已启用，弹窗出现时需点击**允许**。如果当时错过或点了拒绝，手动添加放行：

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \
    $(brew --prefix)/sbin/dnsmasq
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp \
    $(brew --prefix)/sbin/dnsmasq
```

---

## 验证方法

在 Mac mini 启动出口节点后，从通过它路由的客户端验证：

```bash
# 应返回 Mac mini 的公网 IP
curl -4 ifconfig.me

# DNS 应通过 Mac mini 解析
nslookup google.com 10.66.66.2
```

在 Mac mini 本机验证：

```bash
# 查看 pf NAT 规则
sudo pfctl -a zt-exit -s nat

# 确认 dnsmasq 在 ZeroTier IP 上监听
nc -zv 10.66.66.2 53

# 确认 IP 转发已开启
sysctl net.inet.ip.forwarding
```

---

## 关键问题汇总

| 问题 | 根本原因 | 解决方案 |
|------|---------|---------|
| ZeroTier 接口是 `feth*` 而非 `zt*` | Apple Silicon 使用不同的网络扩展 | 通过 `zerotier-cli listnetworks` 配合正则动态检测 |
| pf 规则加载会清除系统规则 | `-f /etc/pf.conf` 替换所有规则 | 写入 `zt-exit` anchor，与系统规则隔离 |
| dnsmasq 无法绑定 53 端口 | 53 端口为特权端口，需要 root | 始终使用 `sudo brew services start dnsmasq` |
| 重启时报 `Address already in use` | 旧 dnsmasq 进程仍占用 53 端口 | 停止后等待端口释放（`nc -z -w1` 检测），再启动 |
| `lsof -i :53` 返回很慢 | macOS `lsof` 执行全量文件描述符扫描 | 改用 `nc -z -w1` + `pgrep` 组合，毫秒级返回 |
| `sudo brew services` 产生 ownership 警告 | brew 以 root 运行时修改路径所有权 | 仅 dnsmasq 使用 `sudo brew services`；其他服务用 `sudo -u $REAL_USER brew services` |
