# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac。

- **JPEG 流**：低延迟画面传输，兼容所有客户端
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **文件传输**：从客户端发送文件到 Mac `~/Downloads`
- **剪贴板同步**：双向文本同步
- **三端支持**：Windows、macOS（Electron 桌面客户端）+ 任意浏览器（Web 客户端）

---

## 架构

```
Remoter-Mac/        Mac 被控端（Swift · CoreGraphics · Network.framework）
Remoter-Client/     控制端（Electron + React + TypeScript）
                     同一套代码也能构建为纯网页版（无需安装）
Remoter-Server/     公网中继服务器（Node.js WebSocket，可选）
```

---

## Mac 被控端

**系统要求：** macOS 14 Sonoma 或更高（macOS 26 beta 已测试）

### 编译 & 打包

需要 Swift 5.9+（Xcode Command Line Tools 或完整 Xcode）：

```bash
xcode-select --install   # 仅首次

cd Remoter-Mac
bash scripts/build-app.sh          # debug 包
bash scripts/build-app.sh --release  # release 包（更小更快）
```

产物：`Remoter-Mac/build/RemoterAgent.app`

> **内嵌 Web 客户端（可选）**：如果先构建了 Web 客户端（见下方），Mac app 会自动将其打包进去并在端口 7799 提供服务，无需额外部署。

### 首次运行授权

**必须**在系统设置中授权以下两个权限：

- **隐私与安全性 → 屏幕与系统录音** → 允许 RemoterAgent
- **隐私与安全性 → 辅助功能** → 允许 RemoterAgent

启动时 app 会自动弹出授权对话框，按提示操作即可。

### 启动

```bash
open Remoter-Mac/build/RemoterAgent.app              # 随机生成 PIN
open Remoter-Mac/build/RemoterAgent.app --args --pin 123456  # 指定 PIN
```

启动后菜单栏出现 `⬇` 图标，点击可查看 **PIN 码**、**局域网 WebSocket 地址**，以及（内嵌了 Web 客户端时）**Web 客户端地址**。

### 连接日志

日志存储于 `~/Library/Logs/Remoter/connections.log`，可通过菜单栏「在 Finder 中显示日志」快速打开。

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

同一套代码也能构建为网页，在 Chrome / Edge / Safari 等浏览器中直接打开，无需安装任何软件。

**推荐方式：内嵌到 Mac app（一步到位）**

```bash
# 1. 构建 web 产物
cd Remoter-Client
npm install
npm run build:web          # 输出到 Remoter-Client/dist-web/

# 2. 打包 Mac app（自动将 web 产物嵌入 bundle）
cd ../Remoter-Mac
bash scripts/build-app.sh
```

启动 Mac app 后，菜单栏会显示 Web 客户端地址（如 `http://192.168.1.144:7799`）。用其他设备的浏览器打开该地址即可连接。

**开发/调试模式**

```bash
cd Remoter-Client
npm run dev:web        # 在 http://localhost:5174 启动本地开发服务器
```

**独立部署（不内嵌到 Mac app）**

```bash
cd Remoter-Client
npm run build:web
# 用任意静态文件服务器提供 dist-web/ 目录
npx serve dist-web -p 7799
# 或
python3 -m http.server 7799 --directory dist-web
```

> **浏览器兼容性**：Chrome 94+ / Edge 94+ / Safari 15.4+，推荐 Chrome 以获得最佳性能（WebCodecs 支持最完整）。

---

### 连接步骤

1. 打开控制端（桌面 app 或浏览器），选择「直连（局域网）」
2. 输入 Mac 的局域网地址，格式：`ws://192.168.1.x:7788`
3. 输入 **PIN 码**（从 Mac 菜单栏复制）
4. 点击连接，等待画面出现

---

## 跨网络连接

### WireGuard / VPN（推荐）

两端接入同一 WireGuard 网络后，直接填 WireGuard 虚拟 IP 连接：

```
客户端 (10.0.0.2) ──── WireGuard ──── Mac (10.0.0.3)
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
- **E2E 加密**：认证通过后，所有消息均使用 P-256 ECDH + AES-256-GCM 加密
- **局域网直连**：数据不经过任何第三方服务器
- **中继模式**：流量经自建服务器透明转发，E2E 加密对服务器不可见
