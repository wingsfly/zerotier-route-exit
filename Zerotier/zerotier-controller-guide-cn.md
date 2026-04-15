# ZeroTier 自建 Controller 配置指南

## 概述

本文档涵盖 ZeroTier 的安装、在 Linux VPS 上搭建自建 Controller、节点管理及连通性验证。出口节点配置请参考各平台独立文档。

---

## 网络拓扑

```
MacBook (10.66.66.3)    ──┐
                             ├── Linux VPS（Controller，10.66.66.1）
Mac mini (10.66.66.2)   ──┘
GL.iNet (10.66.66.100)  ──┘
Windows (10.66.66.x)    ──┘
```

| 节点 | Node ID | 虚拟 IP | 角色 |
|------|---------|---------|------|
| Linux VPS | `a1b2c3d4e5` | `10.66.66.1` | Controller |
| Mac mini | `b2c3d4e5f6` | `10.66.66.2` | 客户端 / 出口节点 |
| MacBook | `c3d4e5f6a7` | `10.66.66.3` | 客户端 |
| GL.iNet | `d4e5f6a7b8` | `10.66.66.100` | 客户端路由器 |

---

## 一、安装 ZeroTier

### Linux（Ubuntu/Debian）

```bash
curl -s https://install.zerotier.com | sudo bash
sudo systemctl enable zerotier-one
sudo systemctl start zerotier-one
```

### macOS

```bash
# 方式一：官网下载安装包
# https://www.zerotier.com/download/

# 方式二：Homebrew
brew install --cask zerotier-one
```

### Windows

1. 前往 [https://www.zerotier.com/download/](https://www.zerotier.com/download/) 下载 Windows 安装包
2. 双击安装，完成后系统托盘会出现 ZeroTier 图标

### 验证安装

```bash
# Linux
zerotier-cli info

# macOS（需要 sudo）
sudo zerotier-cli info

# Windows（管理员 PowerShell）
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" info
```

正常输出示例：

```
200 info a1b2c3d4e5 1.16.1 ONLINE
```

---

## 二、常见启动问题排查

### 端口占用错误

```
zerotier-one: fatal error: cannot bind to local control interface port 9993
```

说明已有 ZeroTier 进程在运行，检查并处理：

```bash
# 查看是否已有进程
ps aux | grep zerotier

# 查看端口占用
ss -ulnp | grep 9993

# 如有僵尸进程则清除
pkill zerotier-one
zerotier-one -d

# 如通过 systemd 管理，直接查看状态
systemctl status zerotier-one
```

---

## 三、在 Linux VPS 上搭建自建 Controller

> ZeroTier 的 Controller 功能内置于 `zerotier-one`，无需额外安装。

### 3.1 获取节点信息和 Auth Token

```bash
zerotier-cli info
cat /var/lib/zerotier-one/authtoken.secret
```

示例输出：

```
200 info a1b2c3d4e5 1.16.1 ONLINE
b26s7salv8n0697x3ockq8wb
```

> ⚠️ `authtoken.secret` 是访问本地 Controller API 的凭证，请勿泄露，不要提交到 git 仓库。

### 3.2 创建虚拟网络

Network ID = Node ID（10位 hex）+ 自定义后缀（6位 hex），例如 `a1b2c3d4e5` + `f60789` = `a1b2c3d4e5f60789`：

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

成功后返回 JSON，确认 `"id"` 字段即为你的 Network ID。

### 3.3 Controller 节点自身加入网络

Controller 不会自动加入，需手动操作并分配固定 IP：

```bash
# 加入网络
zerotier-cli join a1b2c3d4e5f60789

# 授权自身并分配固定 IP
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)
NODE=$(zerotier-cli info | awk '{print $3}')

curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/$NODE \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.1"]}'
```

---

## 四、客户端节点加入网络

### Linux / macOS

```bash
# Linux
zerotier-cli join a1b2c3d4e5f60789

# macOS（需要 sudo）
sudo zerotier-cli join a1b2c3d4e5f60789
```

### Windows

**方式一：托盘图标操作（推荐）**

1. 右键系统托盘的 ZeroTier 图标
2. 点击 **Join New Network...**
3. 输入 Network ID：`a1b2c3d4e5f60789`
4. 点击 Join

**方式二：命令行（以管理员身份运行 PowerShell）**

```powershell
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" join a1b2c3d4e5f60789
```

查看本机 Node ID（用于在 Controller 上授权）：

```powershell
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" info
```

---

## 五、在 Controller 上授权节点

### 5.1 查看待授权节点列表

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

curl -s http://localhost:9993/controller/network/a1b2c3d4e5f60789/member \
  -H "X-ZT1-Auth: $AUTH"
```

返回示例：

```json
{"c3d4e5f6a7": 1, "e5f6a7b8c9": 1}
```

### 5.2 授权单个节点

```bash
AUTH=$(cat /var/lib/zerotier-one/authtoken.secret)

curl -X POST http://localhost:9993/controller/network/a1b2c3d4e5f60789/member/<nodeId> \
  -H "X-ZT1-Auth: $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"authorized": true, "ipAssignments": ["10.66.66.x"]}'
```

### 5.3 批量授权示例

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

## 六、查看已授权成员详情

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

预期输出：

```
NODE ID         IP ASSIGNMENTS       AUTHORIZED
-----------------------------------------------
c3d4e5f6a7      10.66.66.3          True
d4e5f6a7b8      10.66.66.100        True
b2c3d4e5f6      10.66.66.2          True
a1b2c3d4e5      10.66.66.1          True
```

---

## 七、验证连通性

在任意节点上 ping 其他节点的虚拟 IP：

```bash
# Linux / macOS
ping 10.66.66.1    # Controller
ping 10.66.66.2    # Mac mini
ping 10.66.66.3    # MacBook

# Windows
ping 10.66.66.1
```

查看本机在虚拟网络中的 IP：

```bash
# Linux
zerotier-cli listnetworks

# macOS
sudo zerotier-cli listnetworks

# Windows
& "C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" listnetworks
```

查看 peer 连接状态：

```bash
# Linux
zerotier-cli peers

# macOS
sudo zerotier-cli peers
```

输出字段说明：

| 字段 | 说明 |
|------|------|
| `<ztaddr>` | 对端的 ZeroTier Node ID |
| `<role>` | `LEAF` = 普通节点，`PLANET` = ZeroTier 官方根服务器 |
| `<link>` | `DIRECT` = P2P 打洞成功，`RELAY` = 经由中继转发 |
| `<lat>` | 延迟（ms），`-1` 表示未测量 |
| `<path>` | 对端真实 underlay IP:端口 |

---

## 八、可选：Web 管理界面（ztncui）

通过 curl 管理节点较为繁琐，可部署轻量 Web UI：

```bash
docker run -d \
  --name ztncui \
  --restart always \
  -p 3000:3000 \
  -v /var/lib/zerotier-one:/var/lib/zerotier-one \
  -e ZTNCUI_PASSWD=你的管理员密码 \
  keynetworks/ztncui
```

浏览器访问 `http://<Linux公网IP>:3000`，使用 `admin` / 你设置的密码登录。

> ⚠️ 3000 端口仅对可信 IP 开放，该 UI 拥有完整的 Controller 控制权限。

---

## 常用命令速查

| 操作 | 命令 |
|------|------|
| 查看本机状态 | `zerotier-cli info` |
| 加入网络 | `zerotier-cli join <networkId>` |
| 离开网络 | `zerotier-cli leave <networkId>` |
| 查看已加入网络 | `zerotier-cli listnetworks` |
| 查看所有 peer | `zerotier-cli peers` |
| 读取 Auth Token（Linux） | `cat /var/lib/zerotier-one/authtoken.secret` |
| 读取 Auth Token（macOS） | `cat /Library/Application\ Support/ZeroTier/One/authtoken.secret` |
| 列出 Controller 成员 | `curl -s http://localhost:9993/controller/network/<nwid>/member -H "X-ZT1-Auth: $AUTH"` |
| 授权成员 | `curl -X POST .../member/<nodeId> -d '{"authorized": true, ...}'` |

---

## 注意事项

**不要使用 `allowDefault=1`：**

```bash
# 禁止执行以下命令
zerotier-cli set <networkId> allowDefault=1
```

该选项会让 ZeroTier 完全接管路由，行为不可控，可能导致网络完全断开。本方案中的出口路由均通过独立脚本手动控制。

**peer 列表中的 PLANET 节点：**

`peers` 输出中的 `PLANET` 条目（如 `cafe04eba9`、`cafefd6717`）是 ZeroTier 官方全球根服务器，不是你网络的成员。它们的作用类似 DNS 根服务器，协助节点互相发现并在 P2P 打洞失败时中继流量，不会出现在 Controller 成员列表中。

**Controller API 仅限本机访问：**

Controller API（`http://localhost:9993`）只接受来自 `127.0.0.1` 的请求。从客户端机器访问时，需通过 SSH 隧道：

```bash
ssh -L 19993:127.0.0.1:9993 root@203.0.113.10 -N
curl -s http://127.0.0.1:19993/controller/network/... -H "X-ZT1-Auth: $TOKEN"
```
