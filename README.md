<p align="center">
  <a href="#中文">中文</a> · <a href="#english">English</a>
</p>

---

<a id="中文"></a>

# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac 或 Windows。

- **JPEG 串流**：低延迟画面传输，兼容所有客户端
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **WebRTC DataChannel**：自动协商 UDP 传输通道，进一步降低延迟
- **文件传输**：双向发送文件，保存到目标机 `~/Downloads`
- **剪贴板同步**：双向文本 + 图片自动同步（≤4MB PNG）
- **多标签页**：同时管理多个远程会话，Tab 悬停显示实时延迟 / 帧率 / 连接时长
- **主题切换**：跟随系统 / 浅色 / 深色，实时生效

---

## 一键构建

```bash
# Mac 被控端（含嵌入 Web 客户端）— 在 macOS 上运行
bash scripts/build-mac.sh              # debug 包
bash scripts/build-mac.sh --release    # release 包

# Win 被控端（含嵌入 Web 客户端）— 在 Windows 上运行
powershell -ExecutionPolicy Bypass -File scripts\build-win.ps1
```

产物：
- Mac：`Remoter-Mac/build/RemoterAgent.app`
- Win：`Remoter-Win/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe`（含 `web/` 子目录）

---

## 架构

```
Remoter-Mac/        Mac 被控端     Swift · ScreenCaptureKit · Network.framework
Remoter-Win/        Windows 被控端  C# .NET 8 · DXGI Desktop Duplication · SendInput
Remoter-Client/     控制端          Electron + React + TypeScript
                    同一套代码也能构建为纯网页版（无需安装）
Remoter-Server/     公网中继服务器   Node.js WebSocket（可选）
```

**端口一览**

| 服务 | 端口 | 说明 |
|------|------|------|
| Mac/Win WebSocket | 7788 | 被控端主连接（可 `--port` 覆盖） |
| Mac/Win Web 客户端 | 7799 | 静态文件服务，有 `web/` 时自动开启 |
| Win 管理控制台 | 主端口 + 2 | 默认 7790，日志 / PIN / 状态 |
| 中继服务器 | 7789 | WebSocket 中转 + Web 客户端托管 |

---

## Mac 被控端

**系统要求：** macOS 14 Sonoma 或更高（macOS 26 beta 已测试）

### 编译 & 打包

需要 Swift 5.9+（Xcode Command Line Tools 或完整 Xcode）：

```bash
xcode-select --install   # 仅首次

cd Remoter-Mac
bash scripts/build-app.sh            # debug 包
bash scripts/build-app.sh --release  # release 包（更小更快）
```

产物：`Remoter-Mac/build/RemoterAgent.app`

> **内嵌 Web 客户端（可选）**：先构建 Web 客户端（见下方），`build-app.sh` 会自动将产物打包进 bundle，启动后在端口 7799 提供服务。

### 认证方式

| 方式 | 说明 |
|------|------|
| PIN 码 | 启动时随机生成或 `--pin 123456` 指定，从菜单栏复制 |
| 账号密码 | 使用 macOS 本地账号（通过 `dscl -authonly` 验证） |
| Token | 账密登录成功后自动颁发，下次直连免密 |

### 首次运行授权

**必须**在系统设置中授权以下两个权限：

- **隐私与安全性 → 屏幕与系统录音** → 允许 RemoterAgent
- **隐私与安全性 → 辅助功能** → 允许 RemoterAgent

启动时 app 会自动弹出授权对话框，按提示操作即可。

### 启动

```bash
open Remoter-Mac/build/RemoterAgent.app                      # 随机生成 PIN
open Remoter-Mac/build/RemoterAgent.app --args --pin 123456  # 指定 PIN
```

启动后菜单栏出现 `⬇` 图标，点击可查看 **PIN 码**、**局域网 WebSocket 地址**，以及（内嵌了 Web 客户端时）**Web 客户端地址**。

### 连接日志

日志存储于 `~/Library/Logs/Remoter/connections.log`，可通过菜单栏「在 Finder 中显示日志」快速打开。

### 踩坑记录

- **macOS 15+ 只能看到桌面壁纸**：`CGDisplayCreateImage` 在 macOS 15 会话授权未通过时返回纯壁纸帧；已迁移至 `ScreenCaptureKit (SCStream)`，可触发正确的会话授权弹窗。
- **PAM `pam_start("login")` 非 root 进程鉴权失败**：`"login"` 服务要求特权进程；已改用 `/usr/bin/dscl . -authonly`，无需 root，兼容本地账号和 Apple ID 账号。
- **两个权限弹窗同时出现**：改为顺序申请：先等屏幕录制 `await`，再请求辅助功能。

---

## Windows 被控端

**系统要求：** Windows 10 1803+ x64，.NET 8 Runtime

画面采集使用 **DXGI Desktop Duplication API**（GPU 侧捕获，延迟 < 2ms/帧），输入注入使用 **SendInput** Win32 API。

### 编译

需要 .NET 8 SDK：

```bash
cd Remoter-Win
dotnet publish -r win-x64 -c Release -p:PublishSingleFile=true --self-contained
```

产物：`Remoter-Win/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe`（单文件，无需安装运行时）

### 启动

```
RemoterWin.exe                     # 随机生成 PIN，端口 7788
RemoterWin.exe --pin 123456        # 指定 PIN
RemoterWin.exe --port 7789         # 指定端口
```

### 管理控制台

浏览器访问 `http://localhost:{主端口+2}/`（默认 `http://localhost:7790/`），功能：
- 实时日志流（SSE）
- 热更新 PIN / 端口 / 中继地址（无需重启）
- 连接数 / 运行时间状态

---

## 控制端

有两种形式，使用**同一套 React 代码**：

### A. Electron 桌面客户端（Windows / macOS）

```bash
cd Remoter-Client
npm install
npm run package:win   # 打包 Windows 安装包
npm run package:mac   # 打包 macOS 应用
npm run dev           # 开发模式
```

> **中国大陆网络**（electron 下载慢）：
> ```bash
> ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/" \
> ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/" \
> npm run package:win
> ```

### B. Web 客户端（任意浏览器，无需安装）

```bash
cd Remoter-Client && npm run build:web   # 输出到 Remoter-Server/public/
```

三种托管方式：内嵌 Mac app、内嵌 Win exe、通过中继服务器公网托管。详见下方「自建中继服务器」。

### 连接步骤

1. 打开控制端（桌面 app 或浏览器）
2. 选择「直连（局域网）」，填入被控端地址：`ws://192.168.1.x:7788`
3. 输入 **PIN 码**（从被控端菜单栏复制）或账号密码
4. 点击连接，等待画面出现

---

## 跨网络连接

### 方案一：Tailscale / ZeroTier（推荐）

两台设备安装同一 VPN 客户端后直接用虚拟 IP 直连，无需任何配置：

| VPN | 免费额度 |
|-----|---------|
| **Tailscale** | 个人免费，最多 3 台设备 |
| **ZeroTier** | 个人免费，最多 25 台设备 |

### 方案二：Cloudflare Tunnel（免费公网域名）

```bash
brew install cloudflare/cloudflare/cloudflared
bash Remoter-Mac/scripts/cloudflare-tunnel.sh
```

脚本输出 `https://xxx.trycloudflare.com`，把 `https://` 换成 `wss://` 填入控制端即可。

### 方案三：自建中继服务器

```bash
cd Remoter-Server
npm install && npm run build:all
npm start           # 端口 7789

# 被控端加 --relay 参数
open RemoterAgent.app --args --relay ws://your-server:7789
RemoterWin.exe --relay ws://your-server:7789
```

---

## 安全说明

- **E2E 加密**：P-256 ECDH 密钥交换 + HKDF-SHA256 + AES-256-GCM，握手完成后所有控制消息均加密
- **局域网直连**：数据不经过任何第三方服务器
- **中继模式**：流量经自建服务器透明转发，E2E 加密对中继不可见
- **HTTP 降级**：Web 客户端通过 HTTP 访问时 E2E 自动跳过，建议生产环境配置 TLS

---

<a id="english"></a>

# Remoter

A personal remote desktop tool for controlling Mac or Windows from any device.

- **JPEG streaming** — low-latency screen transfer, compatible with all clients
- **End-to-end encryption** — P-256 ECDH + AES-256-GCM, zero plaintext
- **LAN direct connect** — latency < 20ms
- **Cross-network** — WireGuard / VPN tunnel or self-hosted relay server
- **WebRTC DataChannel** — auto-negotiates UDP transport for lower latency
- **File transfer** — bidirectional, saved to `~/Downloads` on the target machine
- **Clipboard sync** — bidirectional text + image auto-sync (≤4MB PNG)
- **Multi-tab** — manage multiple remote sessions; hover a tab to see live latency / fps / connection duration
- **Theme** — follows system / light / dark, applied instantly

---

## One-command Build

```bash
# Mac agent (with embedded web client) — run on macOS
bash scripts/build-mac.sh              # debug build
bash scripts/build-mac.sh --release    # release build

# Windows agent (with embedded web client) — run on Windows
powershell -ExecutionPolicy Bypass -File scripts\build-win.ps1
```

Output:
- Mac: `Remoter-Mac/build/RemoterAgent.app`
- Win: `Remoter-Win/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe` (with `web/` directory)

---

## Architecture

```
Remoter-Mac/        Mac agent       Swift · ScreenCaptureKit · Network.framework
Remoter-Win/        Windows agent   C# .NET 8 · DXGI Desktop Duplication · SendInput
Remoter-Client/     Controller      Electron + React + TypeScript
                    Same codebase builds as a pure web app (no install needed)
Remoter-Server/     Relay server    Node.js WebSocket (optional)
```

**Ports**

| Service | Port | Notes |
|---------|------|-------|
| Mac/Win WebSocket | 7788 | Agent main connection (override with `--port`) |
| Mac/Win Web client | 7799 | Static file server, auto-starts when `web/` exists |
| Win admin console | main port + 2 | Default 7790, logs / PIN / status |
| Relay server | 7789 | WebSocket relay + web client hosting |

---

## Mac Agent

**Requirements:** macOS 14 Sonoma or later (macOS 26 beta tested)

### Build

Requires Swift 5.9+ (Xcode Command Line Tools or full Xcode):

```bash
xcode-select --install   # first time only

cd Remoter-Mac
bash scripts/build-app.sh            # debug build
bash scripts/build-app.sh --release  # release build (smaller & faster)
```

Output: `Remoter-Mac/build/RemoterAgent.app`

### Authentication

| Method | Description |
|--------|-------------|
| PIN | Randomly generated on startup, or set with `--pin 123456`; copy from menu bar |
| Username / Password | macOS local account (verified via `dscl -authonly`) |
| Token | Issued automatically after credential login; enables passwordless reconnect |

### First-run Permissions

Grant the following in **System Settings**:

- **Privacy & Security → Screen Recording** → allow RemoterAgent
- **Privacy & Security → Accessibility** → allow RemoterAgent

The app prompts for both automatically on first launch.

### Launch

```bash
open Remoter-Mac/build/RemoterAgent.app                      # random PIN
open Remoter-Mac/build/RemoterAgent.app --args --pin 123456  # fixed PIN
```

A `⬇` icon appears in the menu bar. Click it to see the **PIN**, **LAN WebSocket address**, and (if web client is embedded) the **web client URL**.

### Troubleshooting

- **macOS 15+ shows only the desktop wallpaper**: `CGDisplayCreateImage` returns a wallpaper-only frame when session auth is not approved. Fixed by migrating to `ScreenCaptureKit (SCStream)`, which triggers the correct session auth dialog.
- **PAM `pam_start("login")` fails for non-root processes**: the `"login"` service requires elevated privileges. Fixed by using `/usr/bin/dscl . -authonly` instead — no root needed, works for local accounts and Apple ID accounts.
- **Two permission dialogs appearing simultaneously**: fixed by requesting them sequentially — screen recording first (`await`), then accessibility.

---

## Windows Agent

**Requirements:** Windows 10 1803+ x64, .NET 8 Runtime

Screen capture uses **DXGI Desktop Duplication API** (GPU-side, < 2ms/frame). Input injection uses **SendInput** Win32 API.

### Build

Requires .NET 8 SDK:

```bash
cd Remoter-Win
dotnet publish -r win-x64 -c Release -p:PublishSingleFile=true --self-contained
```

Output: `RemoterWin.exe` (single file, no runtime install needed)

### Launch

```
RemoterWin.exe                     # random PIN, port 7788
RemoterWin.exe --pin 123456        # fixed PIN
RemoterWin.exe --port 7789         # custom port
```

### Admin Console

Open `http://localhost:{port+2}/` (default `http://localhost:7790/`) to:
- Stream real-time logs (SSE)
- Hot-update PIN / port / relay URL (no restart needed)
- View connection count and uptime

---

## Controller

Two forms, built from the **same React codebase**:

### A. Electron desktop client (Windows / macOS)

```bash
cd Remoter-Client
npm install
npm run package:win   # Windows installer
npm run package:mac   # macOS app
npm run dev           # dev mode
```

> **Slow downloads in mainland China** (Electron mirror):
> ```bash
> ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/" \
> ELECTRON_BUILDER_BINARIES_MIRROR="https://npmmirror.com/mirrors/electron-builder-binaries/" \
> npm run package:win
> ```

### B. Web client (any browser, no install)

```bash
cd Remoter-Client && npm run build:web   # outputs to Remoter-Server/public/
```

Three hosting options: embed in Mac app, embed in Win exe, or host via relay server.

### How to Connect

1. Open the controller (desktop app or browser)
2. Choose **Direct (LAN)**, enter the agent address: `ws://192.168.1.x:7788`
3. Enter the **PIN** (copy from the agent's menu bar) or username/password
4. Click Connect and wait for the screen to appear

---

## Cross-network

### Option 1: Tailscale / ZeroTier (recommended)

Install the same VPN client on both machines and connect with the virtual IP — no config needed:

| VPN | Free tier |
|-----|-----------|
| **Tailscale** | Free for personal use, up to 3 devices |
| **ZeroTier** | Free for personal use, up to 25 devices |

### Option 2: Cloudflare Tunnel (free public URL)

```bash
brew install cloudflare/cloudflare/cloudflared
bash Remoter-Mac/scripts/cloudflare-tunnel.sh
```

The script prints `https://xxx.trycloudflare.com` — replace `https://` with `wss://` and paste it into the controller.

### Option 3: Self-hosted relay server

```bash
cd Remoter-Server
npm install && npm run build:all
npm start           # port 7789

# Start agents with --relay
open RemoterAgent.app --args --relay ws://your-server:7789
RemoterWin.exe --relay ws://your-server:7789
```

---

## Security

- **E2E encryption**: P-256 ECDH key exchange + HKDF-SHA256 + AES-256-GCM; all control messages encrypted after handshake
- **LAN direct**: data never leaves your local network
- **Relay mode**: traffic is relayed transparently; E2E encryption is opaque to the relay
- **HTTP fallback**: E2E is skipped when the web client connects over plain HTTP; configure TLS for production use
