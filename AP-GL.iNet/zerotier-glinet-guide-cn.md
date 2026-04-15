# ZeroTier 出口节点配置指南 — GL.iNet + Mac mini

## 概述

本文档记录了通过 GL.iNet 路由器（GL-MT3000，固件版本 4.8.1）将所有 LAN 流量路由至 ZeroTier 出口节点（Mac mini）的完整配置过程，包括网络架构、调试过程中遇到的关键问题及最终解决方案。

---

## 网络架构

```
LAN 设备（MacBook、手机等）
    │
    ▼
GL.iNet 路由器（GL-MT3000）
    │  ZeroTier IP：10.66.66.100
    │  ZeroTier 接口：ztabc12345
    │
    ▼  [ZeroTier 隧道]
Mac mini（出口节点）
    │  ZeroTier IP：10.66.66.2
    │  ZeroTier 接口：feth2351
    │  运行：zt-exit-node.sh
    │
    ▼
公网互联网
```

### ZeroTier 网络节点信息

| 节点 | ZeroTier ID | 虚拟 IP | 角色 |
|------|-------------|---------|------|
| 自建 Controller | a1b2c3d4e5 | 10.66.66.1 | 控制器 |
| Mac mini | b2c3d4e5f6 | 10.66.66.2 | 出口节点 |
| GL.iNet | — | 10.66.66.100 | 客户端路由器 |

---

## Mac mini 出口节点配置

### macOS 特殊说明

**接口命名差异：** Apple Silicon Mac 上，ZeroTier 接口以 `feth<数字>` 命名（虚拟以太网），而非 Linux 上的 `zt<hash>`。检测方法：

```bash
ZT_IFACE=$(sudo zerotier-cli listnetworks | grep -oE '(zt[a-z0-9]+|feth[0-9]+)' | head -1)
```

**Homebrew 路径差异：** Apple Silicon 的 Homebrew 安装在 `/opt/homebrew`，Intel Mac 在 `/usr/local`。建议动态获取：

```bash
BREW_PREFIX=$(sudo -u "$REAL_USER" brew --prefix 2>/dev/null)
```

### pf NAT 配置

macOS 使用 `pf` 作为防火墙。系统 `/etc/pf.conf` 中已声明 `zt-exit` anchor，直接向其写入规则，无需修改 `pf.conf`：

```bash
sudo tee /etc/pf.anchors/zt-exit << EOF
nat on en0 from 10.66.66.0/24 to any -> (en0)
pass in on feth2351 from 10.66.66.0/24 to any keep state
pass out on en0 from 10.66.66.0/24 to any keep state
EOF

sudo pfctl -e 2>/dev/null || true
sudo pfctl -a zt-exit -f /etc/pf.anchors/zt-exit 2>/dev/null
```

验证规则是否生效（注意要用 `-a zt-exit` 指定 anchor）：

```bash
sudo pfctl -a zt-exit -s nat
```

### dnsmasq DNS 服务

通过 Homebrew 安装，配置监听 ZeroTier 接口的 IP：

```
bind-interfaces
listen-address=10.66.66.2
server=8.8.8.8
server=1.1.1.1
no-dhcp-interface=feth2351
```

**重要：** 绑定 53 端口需要 root 权限，必须使用 `sudo brew services start dnsmasq`。以普通用户身份启动会导致 `Address already in use` 错误。

重启时避免端口冲突，应先停止并等待端口释放再启动：

```bash
sudo brew services stop dnsmasq
sleep 2
while pgrep -x dnsmasq >/dev/null && nc -z -w1 "$ZT_IP" 53 2>/dev/null; do
    sleep 1
done
sudo brew services start dnsmasq
```

### Mac mini 脚本：`zt-exit-node.sh`

脚本放置于 `/usr/local/bin/zt-exit-node.sh`，使用方式：

```bash
/usr/local/bin/zt-exit-node.sh start    # 启动出口节点
/usr/local/bin/zt-exit-node.sh stop     # 停止出口节点
/usr/local/bin/zt-exit-node.sh status   # 查看状态
```

#### macOS 开机自启（launchd）

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

加载自启：

```bash
sudo launchctl load /Library/LaunchDaemons/com.zerotier.exitnode.plist
```

---

## GL.iNet 路由器配置

### GL.iNet 固件内部机制（4.8.1）

GL.iNet 固件在 OpenWrt 基础上添加了多个非标准的 iptables 链和路由规则，配置自定义路由脚本时必须了解这些机制。

#### 系统预置 ip rule 规则表

```
0:     from all lookup local
100:   from all fwmark 0x64 lookup 100       ← 我们的策略路由规则
800:   from all lookup 9910 suppress_prefixlength 0
6000:  from all fwmark 0x8000/0xf000 lookup main
9000:  not from all fwmark 0/0xf000 lookup main
9910:  not from all fwmark 0/0xf000 blackhole
9920:  from all iif br-lan blackhole         ← GL.iNet 兜底 blackhole
32766: from all lookup main
32767: from all lookup default
```

规则 `9920` 是 GL.iNet 添加的兜底黑洞，会丢弃所有未被更高优先级规则处理的 br-lan 流量。我们的 fwmark 规则优先级为 100，必须在此之前命中。

#### ROUTE_POLICY 链

GL.iNet 的 mangle 表 `ROUTE_POLICY` 链在所有 br-lan 流量上运行，其中有一条关键规则：

```
RETURN  udp  --  *  *  0.0.0.0/0  0.0.0.0/0  udp dpt:53
```

**这导致所有 DNS 查询（UDP 53 端口）在策略路由生效前就被 RETURN 返回，由本地 dnsmasq 处理**，无论 `uci server` 指向何处都不生效。

#### ZeroTier 防火墙 Zone

GL.iNet 会创建 `zerotier` 防火墙 zone，但**默认不配置 `lan` 和 `zerotier` 之间的转发规则**，导致 LAN 和 ZeroTier 接口之间无法转发流量。

---

### 关键问题与解决方案

#### 问题一：IPv6 流量绕过隧道

域名解析可能返回 IPv6 地址（AAAA 记录），但 ZeroTier 隧道只承载 IPv4，IPv6 数据包无出口被丢弃。

**现象：**
```
ping google.com
PING google.com (2607:f8b0:400a:809::200e)  ← IPv6 地址
14 packets transmitted, 0 packets received  ← 全部丢包
```

**解决方案：** 隧道启用时禁用 IPv6：

```bash
# 启动时
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

# 停止时恢复
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
```

---

#### 问题二：LAN 设备流量被防火墙阻断

GL.iNet 默认不允许 LAN 和 ZeroTier 接口之间转发，导致 LAN 设备 ping 不通外网（ICMP 可以，TCP 不行）。

**现象：**
```
curl -4 ifconfig.me   ← 超时
wget http://...       ← 无法连接
```

**根本原因：** iptables FORWARD 链没有 `br-lan ↔ zt*` 的放行规则。

**解决方案：** 手动添加双向转发规则：

```bash
# 启动时
iptables -I FORWARD -i br-lan -o "$ZT_IFACE" -j ACCEPT
iptables -I FORWARD -i "$ZT_IFACE" -o br-lan -j ACCEPT

# 停止时删除
iptables -D FORWARD -i br-lan -o "$ZT_IFACE" -j ACCEPT 2>/dev/null
iptables -D FORWARD -i "$ZT_IFACE" -o br-lan -j ACCEPT 2>/dev/null
```

---

#### 问题三：DNS 查询无法到达出口节点（核心难点）

这是最复杂的问题。LAN 设备的 DNS 请求发送到路由器（`192.168.32.1:53`），但始终无法转发到 Mac mini（`10.66.66.2:53`）。

**排查过程：**

1. 在路由器上直接查询可以成功：
   ```bash
   nslookup www.baidu.com 10.66.66.2  # ✅ 成功
   ```

2. dnsmasq 开启日志后，LAN 设备的请求完全没有到达 dnsmasq：
   ```bash
   logread -f | grep dnsmasq  # 无任何输出
   ```

3. 查看 `ROUTE_POLICY` 链发现关键规则：
   ```
   RETURN  udp  --  udp dpt:53
   ```
   GL.iNet 在策略路由之前把所有 UDP/53 流量 RETURN 掉，交给本地 dnsmasq 处理。

4. dnsmasq 配置了 `localservice=1`，只响应来自本机的查询，不转发来自 LAN 客户端的外部请求。

5. `uci add_list dhcp.@dnsmasq[0].server="10.66.66.2"` 写入后也无效，因为 ROUTE_POLICY 拦截发生在 dnsmasq 上游转发之前。

**解决方案：** 使用 iptables DNAT，在 NAT PREROUTING 阶段（早于 mangle ROUTE_POLICY）直接重定向 DNS 请求：

```bash
# 启动时
iptables -t nat -I PREROUTING -i br-lan -p udp --dport 53 \
    -j DNAT --to-destination "$ZT_DNS:53"
iptables -t nat -I PREROUTING -i br-lan -p tcp --dport 53 \
    -j DNAT --to-destination "$ZT_DNS:53"

# 停止时删除
iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 \
    -j DNAT --to-destination "$ZT_DNS:53" 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 \
    -j DNAT --to-destination "$ZT_DNS:53" 2>/dev/null
```

**原理：** NAT 表的 PREROUTING 在 mangle 表的 ROUTE_POLICY 之前处理，DNAT 直接修改数据包目标地址，绕过了 GL.iNet 的 DNS 劫持机制。

---

#### 问题四：dnsmasq 配置目录不存在

GL.iNet 默认不创建 `/etc/dnsmasq.d/` 目录，导致写入配置文件失败：

```
tee: /etc/dnsmasq.d/zt-dns.conf: nonexistent directory
```

实际的运行时配置目录是 `/tmp/dnsmasq.d/`，但由于采用了 DNAT 方案（问题三），这个问题已不再相关，无需修改 dnsmasq 配置。

---

### GL.iNet 脚本：`zt-route.sh`

脚本放置于 `/root/zt-route.sh`，使用方式：

```bash
/root/zt-route.sh start    # 启动，所有流量经 ZeroTier 出口
/root/zt-route.sh stop     # 停止，恢复正常路由
/root/zt-route.sh status   # 查看当前状态
/root/zt-route.sh restart  # 重启
```

#### GL.iNet 开机自启（init.d）

创建 `/etc/init.d/zt-route`：

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

验证自启链接是否创建成功：

```bash
ls -la /etc/rc.d/ | grep zt-route
# S99zt-route -> ../init.d/zt-route  （开机启动）
# K10zt-route -> ../init.d/zt-route  （关机停止）
```

`S99` 表示启动顺序 99（确保在 ZeroTier 服务之后启动），`K10` 表示关机时第 10 个停止。

---

## 操作顺序

**启动（先启动出口节点，再启动路由）：**

```bash
# 1. Mac mini 上
/usr/local/bin/zt-exit-node.sh start
/usr/local/bin/zt-exit-node.sh status

# 2. GL.iNet 上
/root/zt-route.sh start
/root/zt-route.sh status
```

**停止（先停路由，再停出口节点）：**

```bash
# 1. GL.iNet 上
/root/zt-route.sh stop

# 2. Mac mini 上
/usr/local/bin/zt-exit-node.sh stop
```

---

## 验证方法

在连接到 GL.iNet 的 LAN 设备上：

```bash
# 应返回 Mac mini 的公网 IP，而非 GL.iNet 的 WAN IP
curl -4 ifconfig.me

# DNS 应通过 Mac mini 解析
nslookup google.com
```

在 GL.iNet 路由器本身（路由器自身流量不会被 mark，走本地路由）：

```bash
# 返回 GL.iNet 自身的 WAN IP，这是正常现象
curl -4 ifconfig.me
```

---

## 关键问题汇总

| 问题 | 根本原因 | 解决方案 |
|------|---------|---------|
| LAN 设备无法上网 | ZeroTier 防火墙 zone 缺少转发规则 | 添加 iptables FORWARD 双向放行 |
| DNS 解析失败 | GL.iNet ROUTE_POLICY 链拦截 UDP/53，uci server 设置无效 | 使用 iptables DNAT 重定向 DNS 到出口节点 |
| 域名解析返回 IPv6 后丢包 | ZeroTier 隧道只承载 IPv4 | 启用隧道时通过 sysctl 禁用 IPv6 |
| macOS ZeroTier 接口非 `zt*` | Apple Silicon 使用 `feth<n>` 接口命名 | 通过 `zerotier-cli listnetworks` 配合 grep 动态检测 |
| macOS dnsmasq 端口冲突 | 旧进程仍占用 53 端口时新进程尝试绑定 | stop 后等待端口释放再 start |
| `sudo brew services` 产生 ownership 警告 | brew services 不应以 root 运行 | 普通服务用 `sudo -u $REAL_USER brew services`；需要绑定 53 端口的服务用 `sudo brew services` |
