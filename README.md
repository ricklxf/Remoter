🇨🇳 **CN** | [🇺🇸 EN](README_EN.md)

---

# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac 或 Windows。

- **RTP 媒体轨道传输**：屏幕帧直接喂给 libwebrtc 的 `RTCVideoSource`，原生编码 + GCC 拥塞控制 + NACK/PLI 丢包重传/关键帧请求 + 抖动缓冲，自动协商 UDP 传输，取代早期手写的 DataChannel 分片方案（Mac 端）
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **音频转发**：系统声音 AAC-LC 编码转发，客户端 WebCodecs 解码播放（默认关闭，控制菜单手动开启）
- **远端光标形状同步**：光标位置本地零延迟渲染，形状轮询同步（文本光标、调整大小箭头等）
- **中文输入法（IME）透传**：本地输入法正常组词选字，只有确定的文字才发送到远端注入
- **多显示器**：可选择远程哪块屏幕
- **延迟分解统计**：编码 / 网络 / 解码三段耗时分别展示
- **断线自动重协商**：WebRTC ICE 断开后自动重建，不需要重连整个会话
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
Remoter-Mac/        Mac 被控端     Swift · ScreenCaptureKit · WebRTC (RTP) · Network.framework
Remoter-Win/        Windows 被控端  C# .NET 8 · DXGI Desktop Duplication · SendInput
                    暂无 WebRTC 实现，视频走 WebSocket 传输
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
- **SCStream 的 CVPixelBuffer 不能跨异步队列持有**：回调返回后底层 IOSurface 会被池子复用，异步派发去编码会读到被下一帧覆盖到一半的数据（表现为随机位置花屏）；必须在回调内同步提交给 VideoToolbox。
- **VideoToolbox 编码回调线程不能做网络发送**：回调不返回，VT 内部队列不释放空位，下游网络一慢编码提交就被拖死（帧率周期性崩到个位数）；已把发送挪到独立队列。
- **H.264 用 High profile 而不是 Baseline**：B 帧由 `AllowFrameReordering=false` 单独禁用即可满足低延迟，Baseline 额外放弃 CABAC/8x8 变换白丢 10-20% 压缩率；WebCodecs 对 High 支持极好。
- **关键帧间隔从 2s 放长到 10s**：关键帧是增量帧的 10-20 倍大，2s 一个在 2Mbps 档位下光关键帧就占约 20% 带宽；按需 `request_keyframe`（丢帧/切 tab/解码过载时客户端主动要）已覆盖所有恢复场景。
- **客户端解码跟不上的信号是 `kfReq`**：网络指标（fps/RTT）测的是"到达"不是"解码"，解码端过载时它们全部正常；靠 WebCodecs `decodeQueueSize` 积压检测 + 主动要关键帧来发现和恢复。
- **画质自适应拆两路**：fps 跟解码过载信号（`kfReq`）走、码率跟发送背压（`bpDrops`）走，各自独立升降档，避免"一个出问题两个一起降"。
- **音频转发**：SCStream `capturesAudio` 采集系统声音 → AAC-LC + ADTS 封装（自描述，客户端 `AudioDecoder('mp4a.40.2')` 免握手）→ 0x03 二进制帧；默认关闭（带宽 + 隐私），控制菜单手动开。
- **中文输入（IME）**：canvas 不是可编辑元素，本地输入法无法在其上组词——藏一个 1px 透明 textarea 持有焦点承接组词，`compositionend` 把最终文本发去远端用 `keyboardSetUnicodeString` 注入；组词期间（`isComposing`/keyCode 229）不 preventDefault 也不转发原始按键。
- **光标形状同步**：采集端隐藏光标、客户端本地渲染（零延迟），形状靠轮询 `NSCursor.currentSystem` 发 PNG+热点给客户端设 CSS cursor；注意光标图要重绘到 point 尺寸，直接用 Retina 2x 位图会显示成双倍大。
- **多显示器**：副屏的鼠标注入必须加 `CGDisplayBounds` 的全局坐标原点偏移——客户端坐标是"相对所选显示器"归一化的，CGEvent 要的是全局桌面坐标。
- **RTP 化：CVPixelBuffer 直接喂给 `RTCVideoSource`**：屏幕帧不再自己拿 VideoToolbox 编码、打包、按 60KB 分片发 DataChannel，改成直接 `source.capturer(_:didCapture:)` 喂给 libwebrtc 的 `RTCVideoSource`（`forScreenCast: true`），编码、拥塞控制（GCC）、丢包重传/关键帧请求（NACK/PLI）、接收端抖动缓冲全部交给协议栈原生实现，取代了此前一整批手写近似方案（分片重组、`bufferedAmount` 背压丢帧、关键帧风暴治理）。RTP 路径下我们自己的反应式自动挡（fps/码率阶梯）会主动让路，避免和 GCC 打架。
- **RTP 连接建立初期画面会经历"模糊到清晰"**：GCC 不知道链路真实带宽，起步码率保守，靠 RTCP 反馈逐步上探直到收敛——这是刻意设计（避免像早期手写自动挡那样直接顶格导致过载卡顿），不是 bug。同理，快速滚动等高时域复杂度内容下画面变糊也是正常现象：编码器要在预算内跟上画面变化速度，必然牺牲清晰度，停止滚动后几秒内会恢复清晰。
- **媒体轨道到达可能早于客户端事件订阅**：本地/局域网连接 ICE 协商极快（单位数毫秒级），libwebrtc 的 `ontrack` 可能在客户端组件挂载、订阅 `media_stream` 事件之前就已经触发；`Connection.emit()` 没有重放机制，这个事件会被直接丢弃——画面完全空白，但延迟/码率统计却显示 RTP 数据在正常流入，容易误判为"传输正常但不渲染"。修复：`Connection` 缓存最近一次到达的 `MediaStream`，供晚订阅的组件补上。
- **`track.muted` 不能用来决定 canvas/video 的显示切换**：`ScreenCaptureKit` 只在画面真正变化时才产出新帧，屏幕静止（比如只是阅读、没有滚动）时 libwebrtc 视频源、进而 track 的 `muted` 状态会频繁 on/off；而服务端一旦切到 RTP 就不再发 WS 兜底帧，底下的 canvas 定格在 RTP 接管那一刻的旧画面。跟着 `muted` 切换显示源，会在"定格的旧帧"和"最新帧"之间反复横跳。修复：`<video>` 一旦到达就保持可见，只有 track 真正结束（`onended`）才退回 canvas 兜底——`<video>` 本身在断流时就会停在最后一帧，这本来就是正确行为。

---

## Windows 被控端

**系统要求：** Windows 10 1803+ x64，.NET 8 Runtime

画面采集使用 **DXGI Desktop Duplication API**（GPU 侧捕获，延迟 < 2ms/帧），输入注入使用 **SendInput** Win32 API。视频传输目前仍走 WebSocket（尚无 WebRTC/RTP 实现）。

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

### 踩坑记录

- **Electron 天然不支持 H.265/HEVC 解码**：标准 Electron 发行版不带 HEVC 软解码器（专利授权问题），硬解钩子（`enable_platform_hevc`）也没有编译进标准构建，不论系统/显卡实际是否支持硬解，`VideoDecoder.isConfigSupported` 探测永远返回不支持——这是 Electron 已知限制，不是本项目代码问题。浏览器（尤其 Chrome 官方版）不受此限制。画质菜单里的编码方式选项因此只在探测到支持时才显示。
- **IME 候选框只能近似居中**：候选框以本地暂存用的隐形 textarea 光标位置为锚点向右展开，浏览器不会把候选框实际宽度暴露给页面查询，做不到像素级精确居中；只能把锚点向左偏移半个"经验候选框宽度"来近似居中效果。
- **Windows 绿色版（portable exe）必须固定解压目录名**：`electron-builder` 的 `portable` 目标默认按打包文件名（含版本号）算解压目录的哈希，只要重新打包升了版本号，解压路径就会变；Windows 防火墙的放行规则是按可执行文件路径记的，路径一变就被当成新程序重新弹授权提示——对着"随时要改 bug、随时打新包"的绿色版工作流，几乎每次启动都会弹。修复：`electron-builder.yml` 里把 `portable.unpackDirName` 固定成常量，不再随文件名变化，不管打多少个新版本都解压到同一路径，防火墙规则只需要放行一次。

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
