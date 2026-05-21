# Remoter

个人远程办公工具，Windows 远程控制 Mac。

- 最高 **2K 超清 60fps** 画质（H.264 硬件编码）
- **超低延迟**：局域网 < 20ms
- **超高速文件传输**：拖拽发送
- **丝滑鼠标操作**：全键盘快捷键透传
- 支持 **局域网直连** 和 **公网中继**

---

## 架构

```
Remoter-Mac/        Mac 被控端（Swift + ScreenCaptureKit + VideoToolbox）
Remoter-Client/     Windows 控制端（Electron + React + WebCodecs）
Remoter-Server/     中继服务器（Node.js WebSocket，可选）
```

---

## 快速开始

### 1. Mac 端（被控机）

**系统要求：** macOS 13 Ventura+

```bash
cd Remoter-Mac
swift build -c release

# 启动（局域网）
.build/release/RemoterAgent --pin 123456 --port 7788

# 启动（含公网中继）
.build/release/RemoterAgent --pin 123456 --relay ws://your-server:7789
```

首次运行需要在系统设置中授权：
- **隐私 → 屏幕录制** → 允许 Terminal
- **隐私 → 辅助功能** → 允许 Terminal

启动后会显示：

```
  PIN: 123456
  Direct connections (LAN):
    ws://192.168.1.100:7788
  Relay session ID: A1B2C3
```

---

### 2. 中继服务器（公网连接，可选）

部署到任意 Node.js 环境：

```bash
cd Remoter-Server
npm install
npm run build
npm start          # 默认端口 7789
PORT=8080 npm start
```

Railway / Fly.io / 腾讯云等均可一键部署。

---

### 3. Windows 客户端

**系统要求：** Windows 10/11 x64，Electron 31+（内置 WebCodecs）

```bash
cd Remoter-Client
npm install

# 开发模式
npm run dev

# 打包 Windows 安装包
npm run package:win
```

打包产物在 `dist/` 目录，双击 `Remoter-Setup-*.exe` 安装。

**连接步骤：**
1. 选择 **直连（局域网）** 或 **中继（公网）**
2. 输入 Mac 的 IP 地址或会话 ID
3. 输入 PIN 码
4. 连接成功后进入远程桌面

---

## 操作说明

| 操作 | 说明 |
|------|------|
| 鼠标移动/点击 | 直接操作，1:1 映射 |
| 滚轮 | 自然方向滚动 |
| 键盘快捷键 | 全部透传（包括 Cmd/Meta） |
| 全屏 | 工具栏点击 ⛶ 按钮 |
| 工具栏 | 鼠标移到屏幕顶部自动显示 |
| 发送文件 | 工具栏点击 📂，保存到 Mac 的 ~/Downloads |
| 剪贴板同步 | 工具栏点击 📋，将本机剪贴板内容发送到 Mac |
| 断开 | 工具栏点击 ⏏ |

---

## 画质预设

| 预设 | 分辨率 | 帧率 | 码率 |
|------|--------|------|------|
| 2K 60fps | 2560×1440 | 60 | 15 Mbps |
| 1080 60fps | 1920×1080 | 60 | 8 Mbps |
| 1080 30fps | 1920×1080 | 30 | 4 Mbps |
| 流畅优先 | 1920×1080 | 30 | 2 Mbps |

---

## 协议说明

所有通信走 WebSocket：
- **文本帧**：JSON 控制消息（认证、输入事件、剪贴板等）
- **二进制帧**：视频帧（H.264 Annex B）和文件分块

视频帧格式：`[0x01][4B frameId][4B ptsMs][1B flags][H.264 NALUs]`

---

## 安全说明

- PIN 码认证，建议使用随机生成的强 PIN
- 局域网直连无流量经过第三方服务器
- 中继模式流量经过自建服务器，端对端不加密（可在此基础上加 TLS）
