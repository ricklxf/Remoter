# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac 或 Windows。

- **JPEG 串流**：低延迟画面传输，兼容所有客户端
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **WebRTC DataChannel**：自动协商 UDP 传输通道，进一步降低延迟
- **文件传输**：双向发送文件，保存到目标机 `~/Downloads`
- **剪贴板同步**：双向文本自动同步
- **多标签页**：同时管理多个远程会话，Tab 标签显示实时延迟
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
Remoter-Mac/        Mac 被控端    Swift · CoreGraphics · Network.framework
Remoter-Win/        Windows 被控端 C# .NET 8 · DXGI Desktop Duplication · SendInput
Remoter-Client/     控制端         Electron + React + TypeScript
                    同一套代码也能构建为纯网页版（无需安装）
Remoter-Server/     公网中继服务器  Node.js WebSocket（可选）
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

启动后日志写入 `remoter.log`（同时控制台输出），有 `web/` 目录时额外打印 Web 地址：

```
╔══════════════════════════════════╗
║      Remoter Windows Agent        ║
╚══════════════════════════════════╝
  PIN  : 481623
  Port : 7788
  LAN  : ws://192.168.1.100:7788
  Admin: http://localhost:7790/
  Web  : http://192.168.1.100:7799/   ← 仅有 web/ 时显示
```

### 管理控制台

浏览器访问 `http://localhost:{主端口+2}/`（默认 `http://localhost:7790/`），功能：
- 实时日志流（SSE）
- 热更新 PIN（无需重启）
- 连接数 / 运行时间状态

**日志文件**：运行目录下 `remoter.log`，超过 10MB 自动轮转为 `remoter.log.bak`。

### 内嵌 Web 客户端（可选）

将 web 产物放到 exe 同目录的 `web/` 文件夹，启动时自动在端口 7799 提供服务：

```bash
# 1. 在项目根目录构建 web 产物（输出到 Remoter-Server/public/）
cd Remoter-Client && npm run build:web

# 2. 将产物复制到 exe 旁边（Windows 命令行）
xcopy /E /I Remoter-Server\public publish\web

# 3. 启动
publish\RemoterWin.exe
```

### 注意事项

- **SendSAS（Ctrl+Alt+Delete）**：需在注册表启用软件 SAS，或以 SYSTEM 身份运行。普通用户模式下会退回 SendInput 注入（安全桌面外有效）。
- **注销 / 重启**：需要 `SeShutdownPrivilege`，以管理员身份运行可确保正常工作。
- **音量静音**：当前版本暂未实现（待补）。

---

## 控制端

有两种形式，使用**同一套 React 代码**：

### A. Electron 桌面客户端（Windows / macOS）

**系统要求：** Windows 10/11 x64 或 macOS 13+

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

打包产物在 `Remoter-Client/dist/`，双击安装包即可使用。

---

### B. Web 客户端（任意浏览器，无需安装）

同一套代码也能构建为网页，在 Chrome / Edge / Safari 等浏览器中直接打开。

`npm run build:web` 将产物输出到 `Remoter-Server/public/`，有三种托管方式：

**方式一：内嵌到 Mac app**

```bash
cd Remoter-Client && npm install && npm run build:web
cd ../Remoter-Mac  && bash scripts/build-app.sh
```

Mac app 启动后菜单栏显示 `http://<LAN-IP>:7799`，局域网内其他设备直接用浏览器访问。

**方式二：内嵌到 Win 被控端**

```bash
cd Remoter-Client && npm run build:web
xcopy /E /I Remoter-Server\public Remoter-Win\...\publish\web   # 复制到 exe 旁
```

Win 服务端启动时在端口 7799 提供服务，同样局域网可访问。

**方式三：通过中继服务器托管（公网访问）**

```bash
cd Remoter-Server
npm install
npm run build:all   # 构建 web 客户端 + 编译服务端 TypeScript
npm start           # 默认端口 7789
```

访问 `http://your-server:7789` 即可打开 web 客户端。建议配 TLS：

```bash
TLS_CERT=/path/to/cert.pem TLS_KEY=/path/to/key.pem npm start
```

HTTPS 下 `crypto.subtle` 可用，E2E 加密自动生效。HTTP 下 E2E 自动降级为明文，控制消息依然经 PIN 验证。

**开发/调试模式**

```bash
cd Remoter-Client
npm run dev:web        # http://localhost:5174
```

> **浏览器兼容性**：Chrome 94+ / Edge 94+ / Safari 15.4+，推荐 Chrome（WebCodecs 支持最完整）。

---

### 连接步骤

1. 打开控制端（桌面 app 或浏览器），点击 `+` 新建连接
2. 选择「直连（局域网）」，输入被控端地址：`ws://192.168.1.x:7788`
3. 输入 **PIN 码**（从被控端日志或菜单栏复制）
4. 点击连接，等待画面出现

---

## 跨网络连接

### 方案一：Tailscale / ZeroTier（推荐，零配置）

两台设备安装同一 VPN 客户端后，Remoter 无需任何改动，直接用虚拟 IP 直连：

| VPN | 免费额度 | 安装 |
|-----|---------|------|
| **Tailscale** | 个人免费，最多 3 台设备，无带宽限制 | [tailscale.com](https://tailscale.com/download) |
| **ZeroTier** | 个人免费，最多 25 台设备 | [zerotier.com](https://www.zerotier.com/download) |

安装并登录同一账号后，Mac 菜单栏「VPN 地址」节会自动显示虚拟 IP：

```
VPN 地址 (Tailscale/ZeroTier)
  ws://100.95.x.x:7788   ← 点击复制
```

控制端连接地址直接填这个 IP 即可，流量走 P2P，不过任何服务器。

---

### 方案二：Cloudflare Tunnel（免费公网域名，无需账号）

不安装 VPN 时，用 cloudflared 把被控端端口临时暴露到公网，自动获得 HTTPS/WSS 域名：

**Mac 被控端**

```bash
# 安装 cloudflared
brew install cloudflare/cloudflare/cloudflared

# 启动隧道（先启动 RemoterAgent，再运行此脚本）
bash Remoter-Mac/scripts/cloudflare-tunnel.sh
```

**Win 被控端**

```powershell
# 下载 cloudflared-windows-amd64.exe → 改名 cloudflared.exe → 放到 PATH
# https://github.com/cloudflare/cloudflared/releases/latest

# 启动隧道（先启动 RemoterWin.exe，再运行此脚本）
.\Remoter-Win\scripts\cloudflare-tunnel.ps1
```

脚本运行后会打印类似：

```
https://abc-def-ghi.trycloudflare.com
```

把 `https://` 换成 `wss://` 填入控制端「直连地址」即可。每次重启隧道域名会变化；WSS 连接意味着 E2E 加密自动生效。

---

### 方案三：自建中继服务器

适用于需要固定地址或多人共享的场景，部署到任意 Node.js 环境：

```bash
cd Remoter-Server
npm install
npm run build:all   # 同时构建 web 客户端和服务端
npm start           # 端口 7789，兼作 WebSocket 中转和 Web 客户端托管
```

被控端启动时加 `--relay` 参数连接中继：

```bash
# Mac
open RemoterAgent.app --args --relay ws://your-server:7789

# Win
RemoterWin.exe --relay ws://your-server:7789
```

控制端填写中继服务器地址（`ws://your-server:7789`）和被控端 PIN 即可跨网络连接。

---

### 方案四：WireGuard / 其他 VPN

两端接入同一 WireGuard 网络后，直接填虚拟 IP 连接，原理与 Tailscale 相同：

```
客户端 (10.0.0.2) ──── WireGuard ──── 被控端 (10.0.0.3)
```

---

## 控制端操作说明

| 操作 | 说明 |
|------|------|
| 鼠标移动 / 点击 | 直接操作，1:1 映射 |
| 滚轮 | 自然方向滚动 |
| 键盘快捷键 | 全部透传（含 Cmd/Meta） |
| 工具栏 | 鼠标移到画面顶部中央 ▼ 按钮显示，3 秒无操作自动隐藏 |
| 画质切换 | 工具栏左侧下拉，2K·60fps / 1080·60fps / 1080·30fps / 流畅优先 |
| 控制菜单 | 发送 Ctrl+Alt+Delete、剪贴板同步开关、禁用被控端键鼠、锁屏 / 注销 / 重启 |
| 文件管理器 | 工具栏 📁，浏览目录并收发文件 |
| 主题切换 | 工具栏 💻/☀️/🌙，在跟随系统 / 浅色 / 深色之间循环 |
| 全屏 | 工具栏 ⛶ |
| 多标签页 | 顶部标签栏，鼠标悬停 Tab 显示延迟 / 帧率 / 码率弹窗 |
| 静音远端 | Tab 上 🔊 按钮 |
| 断开 / 关闭 | Tab 上 × 按钮 |

---

## 安全说明

- **PIN 认证**：连接前必须验证 PIN（生产环境请启用，开发模式默认跳过）
- **E2E 加密**：P-256 ECDH 密钥交换 + HKDF-SHA256 派生 + AES-256-GCM 加密，握手完成后所有控制消息均加密
- **局域网直连**：数据不经过任何第三方服务器
- **中继模式**：流量经自建服务器透明转发，E2E 加密对中继服务器不可见
- **HTTP 降级**：Web 客户端通过 HTTP 访问时，`crypto.subtle` 不可用，E2E 自动跳过，建议生产环境配置 TLS
