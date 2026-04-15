> English version: [README_EN.md](README_EN.md)

# ZeroTier 多地网络与出口总览手册

本项目用于搭建一个可扩展的 ZeroTier 私有网络，并支持两种互联网出口使用方式：

- 方式 A（设备级）：客户端手动切换出口（Mac / Windows）
- 方式 B（网络级）：连接指定 WiFi AP（GL.iNet）后自动通过目标出口上网

本文档只给出从 0 到 1 的完整路径和跳转入口；具体操作命令请进入对应子文档。

---

## 1. 最终目标与角色分工

建议最小角色如下：

- Controller（建议 Linux VPS）：负责网络控制与节点授权
- Exit Node（一个或多个，按地区部署）：负责 NAT + DNS + 出口转发
- Client（Mac / Windows / 手机等）：最终使用出口访问互联网
- WiFi AP（可选，GL.iNet）：让连接到 AP 的终端自动走指定出口

参考：

- Controller 配置（中）：[Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
- Controller configuration (EN): [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)

---

## 2. 总体执行顺序（推荐）

1. 安装 ZeroTier（Controller + 所有节点）
2. 在 Controller 创建网络并设置网段
3. 让各节点加入网络并在 Controller 授权
4. 按地区部署一个或多个 Exit Node（macOS 或 Linux）
5. 选择实际使用方式：
   - 5A. 客户端手动切换出口
   - 5B. 通过 GL.iNet WiFi AP 固定走某个出口
6. 做联通性与出口 IP 验证

---

## 3. 从零开始：对应文档入口

### 步骤 1：安装 ZeroTier

- 入口（含 Linux / macOS / Windows 安装）：
  [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  中的“**一、安装 ZeroTier**”

### 步骤 2：创建网络（Controller）

- 入口：
  [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  中的“**三、在 Linux VPS 上搭建自建 Controller**”

### 步骤 3：节点加入 + 授权

- 节点加入：
  [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  中的“**四、客户端节点加入网络**”
- Controller 授权：
  [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  中的“**五、在 Controller 上授权节点**”

### 步骤 4：配置出口节点（按地区重复）

每新增一个地区出口，就重复本步骤一次。

- macOS 出口节点（推荐 Mac mini）：
  [Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md](Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md)
- Linux 出口节点：
  [Exit-Mac_Linux/linux-exit-node-guide-cn.md](Exit-Mac_Linux/linux-exit-node-guide-cn.md)

配套脚本：

- macOS：[`Exit-Mac_Linux/zt-exit-node.sh`](Exit-Mac_Linux/zt-exit-node.sh)
- Linux：[`Exit-Mac_Linux/zt-exit-node-linux.sh`](Exit-Mac_Linux/zt-exit-node-linux.sh)

---

## 4. 出口使用方式 A：客户端手动切换出口

适用场景：单台设备按需切换到某个地区出口，不影响同网其他设备。

文档入口：

- 中文： [Client-Mac_Windows/zt-exit-client-guide-cn.md](Client-Mac_Windows/zt-exit-client-guide-cn.md)
- English: [Client-Mac_Windows/zt-exit-client-guide.md](Client-Mac_Windows/zt-exit-client-guide.md)

配套脚本：

- Mac：[`Client-Mac_Windows/zt-exit-mac.sh`](Client-Mac_Windows/zt-exit-mac.sh)
- Windows：[`Client-Mac_Windows/zt-exit-windows.ps1`](Client-Mac_Windows/zt-exit-windows.ps1)

建议流程：

1. 先在 Controller 中完成授权
2. 在客户端执行 `list` 查看可选节点
3. 执行 `enable <出口虚拟IP>` 切换出口
4. 完成后执行 `disable` 恢复默认路由

---

## 5. 出口使用方式 B：连接 WiFi AP 自动走指定出口

适用场景：手机/平板/客人设备等不方便单独配置的终端，接入 AP 后统一出网。

文档入口：

- 中文： [AP-GL.iNet/zerotier-glinet-guide-cn.md](AP-GL.iNet/zerotier-glinet-guide-cn.md)
- English: [AP-GL.iNet/zerotier-glinet-guide.md](AP-GL.iNet/zerotier-glinet-guide.md)

配套脚本：

- 路由策略脚本：[`AP-GL.iNet/zt-route.sh`](AP-GL.iNet/zt-route.sh)
- init.d 启动脚本：[`AP-GL.iNet/init.d/zt-route`](AP-GL.iNet/init.d/zt-route)

关键点：

1. 先启动出口节点（Mac mini / Linux）
2. 再在 GL.iNet 启动 `zt-route.sh`
3. 终端连接该 AP 后，无需单机改路由

---

## 6. 多地出口扩展建议（最小原则）

当你需要“东京/新加坡/法兰克福”等多个出口时：

1. 每个地区准备一台 Exit Node
2. 所有 Exit Node 加入同一个 ZeroTier 网络并授权
3. 给每台 Exit Node 分配固定虚拟 IP（便于客户端 `enable <IP>`）
4. 客户端按需切换目标出口 IP
5. 若使用 AP 方案，则每个 AP 绑定一个固定出口 IP

实现细节仍按第 4、5 节对应文档执行。

---

## 7. 验收清单（上线前）

1. 所有节点 `listnetworks` 显示 `OK`
2. Controller 能看到并授权全部成员
3. 每个 Exit Node 的 `start/status` 正常
4. 客户端 `enable` 后公网 IP 与目标地区一致
5. 客户端 `disable` 后公网 IP 恢复本地出口
6. AP 接入终端访问公网时，出口 IP 与 AP 绑定目标一致

---

## 8. 文档索引

- Controller：
  - [Zerotier/zerotier-controller-guide-cn.md](Zerotier/zerotier-controller-guide-cn.md)
  - [Zerotier/zerotier-controller-guide.md](Zerotier/zerotier-controller-guide.md)
- Exit Node：
  - [Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md](Exit-Mac_Linux/mac-mini-exit-node-guide-cn.md)
  - [Exit-Mac_Linux/mac-mini-exit-node-guide.md](Exit-Mac_Linux/mac-mini-exit-node-guide.md)
  - [Exit-Mac_Linux/linux-exit-node-guide-cn.md](Exit-Mac_Linux/linux-exit-node-guide-cn.md)
  - [Exit-Mac_Linux/linux-exit-node-guide.md](Exit-Mac_Linux/linux-exit-node-guide.md)
- Client：
  - [Client-Mac_Windows/zt-exit-client-guide-cn.md](Client-Mac_Windows/zt-exit-client-guide-cn.md)
  - [Client-Mac_Windows/zt-exit-client-guide.md](Client-Mac_Windows/zt-exit-client-guide.md)
- GL.iNet AP：
  - [AP-GL.iNet/zerotier-glinet-guide-cn.md](AP-GL.iNet/zerotier-glinet-guide-cn.md)
  - [AP-GL.iNet/zerotier-glinet-guide.md](AP-GL.iNet/zerotier-glinet-guide.md)
