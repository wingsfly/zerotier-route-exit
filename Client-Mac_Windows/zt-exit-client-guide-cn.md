# ZeroTier 出口节点 — 客户端配置指南

## 概述

本文档介绍如何在单台客户端设备（Mac 或 Windows）上将所有互联网流量路由至 ZeroTier 出口节点。这是设备级别的配置，与路由器级别（GL.iNet）的方案不同，需要在每台设备上单独操作。

> **注意：** 如果你的设备通过已运行 `zt-route.sh` 的 GL.iNet 路由器上网，流量已经透明代理，无需在客户端做任何配置。

---

## 工作原理

```
客户端设备（Mac 或 Windows）
    │
    │  默认路由改为 ZeroTier 出口节点虚拟 IP
    │
    ▼
ZeroTier 网络
    │
    ▼
出口节点（Mac mini，10.66.66.2）
    │
    ▼
公网互联网
```

客户端脚本的操作流程：

1. 保存当前默认网关
2. 添加 underlay 路由保护，确保 ZeroTier 隧道本身不断开
3. 禁用 IPv6，防止流量绕过隧道
4. 将默认路由改为出口节点的 ZeroTier 虚拟 IP
5. 执行 `disable` 时全部恢复

---

## 前提条件

- ZeroTier 已安装并加入网络（`10.66.66.0/24`）
- 出口节点（Mac mini）已运行 `zt-exit-node.sh start`
- 已有控制器认证信息（仅 Mac 客户端需要）

---

## Mac 客户端

### 配置文件

创建 `~/.config/zt-exit/config.conf`：

```bash
mkdir -p ~/.config/zt-exit
cat > ~/.config/zt-exit/config.conf << 'EOF'
NETWORK_ID=a1b2c3d4e5f60789
CONTROLLER_SSH_HOST=root@203.0.113.10
CONTROLLER_TOKEN=your_auth_token_here
IPV6_SERVICES=("Wi-Fi")
EOF
```

**查找 `IPV6_SERVICES`：** 运行 `filters` 命令列出所有网络服务及其 IPv6 状态：

```bash
./zt-exit-mac.sh filters
```

将输出的第一行直接复制到配置文件的 `IPV6_SERVICES` 字段。

**查找 `CONTROLLER_TOKEN`：**

```bash
# Controller 主机为 Linux
cat /var/lib/zerotier-one/authtoken.secret

# Controller 主机为 macOS
cat /Library/Application\ Support/ZeroTier/One/authtoken.secret
```

**配置 SSH 免密登录到 Controller（推荐）：**

脚本每次执行 `enable` 或 `list` 时都会建立 SSH 隧道连接 Controller。如果未配置 SSH key，每次都会要求输入密码。建议提前配置：

```bash
# 如果本机没有 SSH key，先生成
ssh-keygen -t ed25519 -C "zt-exit-client"

# 将公钥复制到 Controller 主机
ssh-copy-id root@203.0.113.10

# 验证免密登录是否正常
ssh root@203.0.113.10 echo ok
```

**ZeroTier 网络成员资格：**

客户端 Mac 必须已加入 ZeroTier 网络并经过 Controller 授权：

```bash
# 加入网络
sudo zerotier-cli join a1b2c3d4e5f60789

# 验证状态（应显示 OK 并有分配的 IP）
sudo zerotier-cli listnetworks
```

授权操作在 Controller 侧完成，可通过 `my.zerotier.com` 的 Web 界面，或自建 Controller 的 API 进行。

### 安装

```bash
cp zt-exit-mac.sh /usr/local/bin/zt-exit
chmod +x /usr/local/bin/zt-exit
```

### 使用方式

```bash
# 列出可用的出口节点
zt-exit list

# 启用出口节点（将所有流量通过 10.66.66.2 出口）
zt-exit enable 10.66.66.2

# 验证（应返回 Mac mini 的公网 IP）
curl -4 ifconfig.me

# 关闭（恢复正常路由）
zt-exit disable
```

### 工作原理 — Mac

脚本通过 SSH 隧道连接 ZeroTier Controller，查询出口节点的 underlay（真实）IP，然后：

1. 通过原始网关为 underlay IP 添加主机路由，确保默认路由改变后 ZeroTier 隧道本身不断开
2. 删除 ZeroTier 自动添加的虚拟 IP 主机路由（可能与新路由冲突）
3. 禁用 `IPV6_SERVICES` 中所有服务的 IPv6
4. 将默认路由改为出口节点的 ZeroTier 虚拟 IP

执行 `disable` 时，从状态文件 `/tmp/zt_original_gw` 读取原始配置并全部恢复。

### 故障排查 — Mac

```bash
# 查看当前默认路由
route -n get default

# 查看状态文件
cat /tmp/zt_original_gw

# 如果路由卡住，手动恢复
sudo route delete default
sudo route add default <你的原始网关IP>
```

---

## Windows 客户端

> ⚠️ **Windows 脚本尚未经过真实环境测试验证。**
> 脚本的逻辑和思路是正确的，但具体命令行为可能因 Windows 版本不同而有差异。
> 首次使用时请逐步手动验证每个步骤。

### 系统要求

- PowerShell 5.1 或更高版本
- 已安装 ZeroTier One（默认路径：`C:\Program Files (x86)\ZeroTier\One\`）
- 以**管理员身份**运行 PowerShell

**ZeroTier 网络成员资格：**

安装 ZeroTier 后，需加入网络并确认已被授权：

```powershell
# 以管理员身份在 PowerShell 中执行
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" join a1b2c3d4e5f60789

# 验证状态（应显示 OK 并有分配的 IP）
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" listnetworks
```

授权操作在 Controller 侧完成。

**`zerotier-cli.bat` 路径说明：**

脚本默认使用 `C:\Program Files (x86)\ZeroTier\One\` 路径。如果你的安装路径不同，需要修改脚本中的对应路径。可通过以下方式确认实际路径：

```powershell
# 搜索 zerotier-cli
Get-Command zerotier-cli* -ErrorAction SilentlyContinue

# 或直接测试两个常见路径
Test-Path "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat"
Test-Path "C:\Program Files\ZeroTier\One\zerotier-cli.bat"
```

### 允许脚本执行

Windows 默认阻止未签名的 PowerShell 脚本，首次使用前执行一次：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 使用方式

以管理员身份打开 PowerShell：

```powershell
# 启用出口节点
.\zt-exit-windows.ps1 enable 10.66.66.2

# 验证（应返回 Mac mini 的公网 IP）
curl.exe -4 ifconfig.me

# 查看当前状态
.\zt-exit-windows.ps1 status

# 关闭（恢复正常路由）
.\zt-exit-windows.ps1 disable
```

### 工作原理 — Windows

脚本使用 Windows `route` 命令和 PowerShell 的 `Get-NetRoute`/`Get-NetAdapter` 实现：

1. 将当前默认网关和接口信息保存至 `%TEMP%\zt-exit-state.json`
2. 通过 `zerotier-cli` 获取所有活跃 peer 的 underlay IP，通过原始网关添加主机路由
3. 通过 `Disable-NetAdapterBinding` 禁用所有网络适配器的 IPv6
4. 删除当前默认路由，添加经由出口节点虚拟 IP 的新默认路由

执行 `disable` 时恢复默认路由并重新启用 IPv6。

### 手动恢复 — Windows

如果脚本执行失败或路由卡住，以管理员身份在 PowerShell 中手动恢复：

```powershell
# 删除异常默认路由
route delete 0.0.0.0 mask 0.0.0.0

# 恢复原始网关（例如 192.168.1.1）
route add 0.0.0.0 mask 0.0.0.0 192.168.1.1 metric 1

# 重新启用所有适配器的 IPv6
Get-NetAdapter | ForEach-Object {
    Enable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
}

# 删除状态文件
Remove-Item "$env:TEMP\zt-exit-state.json" -Force -ErrorAction SilentlyContinue
```

---

## 验证方法

在任意平台启用后：

```bash
# Mac
curl -4 ifconfig.me

# Windows
curl.exe -4 ifconfig.me
```

返回的 IP 应为 Mac mini 的公网 IP，而非本地 ISP 分配的 IP。

---

## 路由器级别 vs 设备级别对比

| | GL.iNet（`zt-route.sh`）| 设备级别（`zt-exit`）|
|--|------------------------|---------------------|
| 覆盖范围 | 所有 LAN 设备，透明代理 | 仅单台设备 |
| 客户端是否需要配置 | 不需要 | 需要，每台设备单独配置 |
| 对 Windows 是否有效 | 有效（透明） | 需要运行脚本 |
| DNS 处理 | 是（DNAT 到出口节点） | 依赖出口节点 dnsmasq |
| IPv6 处理 | 路由器 sysctl 统一禁用 | 每个适配器单独禁用 |

---

## 关键问题汇总

| 问题 | 平台 | 解决方案 |
|------|------|---------|
| 流量没有走出口节点 | Mac/Win | 确认默认路由已指向 ZeroTier 虚拟 IP |
| 改路由后 ZeroTier 隧道断开 | Mac/Win | 必须在修改默认路由前先添加 underlay 主机路由 |
| DNS 仍然走本地 ISP | Mac/Win | 需要禁用 IPv6；出口节点的 dnsmasq 必须运行 |
| PowerShell 脚本被阻止执行 | Windows | 以管理员身份运行 `Set-ExecutionPolicy RemoteSigned` |
| `route` 命令需要管理员权限 | Windows | 始终以管理员身份运行 PowerShell |
