# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac。

- **H.265 / H.264** 自动切换，最高 2K 60fps
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **WebRTC P2P**：优先 UDP 直连，自动降级到 WebSocket
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **文件传输**：从客户端发送文件到 Mac `~/Downloads`
- **剪贴板同步**：双向文本同步

---

## 架构

```
Remoter-Mac/        Mac 被控端（Swift · ScreenCaptureKit · VideoToolbox · WebRTC）
Remoter-Client/     控制端（Electron + React · WebCodecs · WebRTC）
Remoter-Server/     公网中继服务器（Node.js WebSocket，可选）
```

---

## Mac 被控端

**系统要求：** macOS 13 Ventura 或更高

### 编译 & 打包

需要 Swift 5.9+（Xcode Command Line Tools 或完整 Xcode）：

```bash
xcode-select --install   # 仅首次

cd Remoter-Mac
bash scripts/build-app.sh          # debug 包
bash scripts/build-app.sh --release  # release 包（更小更快）
```

产物：`Remoter-Mac/build/RemoterAgent.app`

### 首次运行授权

**必须**在系统设置中授权以下两个权限，否则无法捕获画面和注入输入：

- **隐私与安全性 → 屏幕与系统录音** → 允许 RemoterAgent
- **隐私与安全性 → 辅助功能** → 允许 RemoterAgent

### 启动

```bash
# 随机生成 PIN
open Remoter-Mac/build/RemoterAgent.app

# 指定 PIN
open Remoter-Mac/build/RemoterAgent.app --args --pin 123456
```

启动后菜单栏出现 `⬇` 图标，点击可查看 **PIN 码**和**局域网地址**。

### 连接日志

日志存储于 `~/Library/Logs/Remoter/connections.log`，JSON Lines 格式，可通过菜单栏「在 Finder 中显示日志」快速打开。

---

## 控制端（Windows / Mac）

**系统要求：** Windows 10/11 x64 或 macOS 13+，需支持 WebCodecs API

### 从源码构建

```bash
cd Remoter-Client
npm install

# 打包 Windows 安装包（自动递增版本号）
npm run package:win

# 打包 Mac 应用
npm run package:mac

# 开发模式（实时热更新）
npm run dev
```

> **中国大陆网络**：electron 二进制下载较慢，可设置镜像：
> ```bash
> ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/" \
> ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/" \
> npm run package:win
> ```

打包产物在 `Remoter-Client/dist/`，双击 `Remoter-Setup-x.x.x.exe` 安装。

### 连接步骤

1. 输入 Mac 的 **IP 地址**（局域网或 VPN 虚拟 IP）
2. 输入 **PIN 码**（从 Mac 菜单栏复制）
3. 点击连接，等待画面出现

---

## 跨网络连接

### WireGuard / VPN（推荐）

两端接入同一 WireGuard 网络后，直接填 WireGuard 虚拟 IP 连接，无需改动任何代码。

```
Windows (10.0.0.2) ──── WireGuard ──── Mac (10.0.0.3)
```

### 中继服务器（可选）

适用于无法使用 VPN 的场景，部署到任意 Node.js 环境：

```bash
cd Remoter-Server
npm install && npm start   # 默认端口 7789

# 启用 TLS
TLS_CERT=/path/to/cert.pem TLS_KEY=/path/to/key.pem npm start
```

---

## 操作说明

| 操作 | 说明 |
|------|------|
| 鼠标移动 / 点击 | 直接操作，1:1 映射 |
| 滚轮 | 自然方向滚动 |
| 键盘快捷键 | 全部透传（含 Cmd/Meta） |
| 全屏 | 工具栏 ⛶ 按钮 |
| 工具栏 | 鼠标移到屏幕顶部自动显示 |
| 发送文件 | 工具栏 📂，保存到 Mac `~/Downloads` |
| 剪贴板同步 | 工具栏 📋，将本机内容发送到 Mac |
| 断开 | 工具栏 ⏏ |

---

## 安全说明

- **PIN 认证**：连接前必须验证 PIN
- **E2E 加密**：PIN 认证通过后，所有消息（包括视频流控制帧）均使用 P-256 ECDH 协商的 AES-256-GCM 加密
- **WebRTC**：视频帧通过 DTLS 加密的 DataChannel 传输
- **局域网直连**：数据不经过任何第三方服务器
- **中继模式**：流量经过自建服务器透明转发，E2E 加密对服务器不可见
