# Remoter-MacClient

纯原生 macOS 远程桌面客户端（**Remoter**），基于 **Swift / AppKit**、**VideoToolbox 硬件解码**、**Metal 零拷贝渲染**、**AudioToolbox + AVAudioEngine 低延迟音频** 与 **原生 macOS 输入/剪贴板同步** 构建，零浏览器 / 零 Electron 开销。

## 核心架构 (Architecture)

- **原生 AppKit 暗色界面 (`UI/`)**：
  - `Theme.swift`：暗色视觉规范（`#121419` / `#1A1E26` / `#252A36` / `#0FB8AB` 青绿强调色）。
  - `ConnectWindowController.swift`：左侧已保存设备列表（支持双击快速连接与删除），右侧支持 **直连 (Direct)** 与 **中继 (Relay)** 模式、TLS 开关、PIN / 账号密码认证。
  - `DesktopWindowController.swift`：原生全屏远程桌面窗口，支持拖拽本地文件到画布直接上传、断线重连提示浮层与非阻塞底部 Toast 通知。
  - `FloatingToolbarPanel.swift`：顶部居中无边框悬浮工具栏（默认折叠为半透明胶囊 `▼ FPS · Mbps · RTT ms`，悬停/点击展开，3 秒无操作自动收起），提供实时 Telemetry HUD、多显示器切换、画质菜单（分辨率 / 缩放模式 / 帧率 / 码率 / H.264 & H.265 / 强制关键帧 / Ctrl+Alt+Del / 锁屏）、音频与音量调节、隐私屏、游戏鼠标、Mac↔Win 键位互换、剪贴板同步与文件传输。
  - `FileTransferSheet.swift`：远端目录浏览器与双向分块文件传输面板，支持双击进入目录/下载、多文件上传与实时传输进度。
- **硬件视频解码与 Metal 渲染 (`Video/`)**：
  - `VideoDecoder.swift`：`VTDecompressionSession` 硬件解码 H.264 / H.265（Annex-B → AVCC/HVCC → NV12 `IOSurface`），支持流中 SPS/PPS/VPS 切换与 JPEG 回退解码。
  - `MetalRenderer.swift`：`MTKView` + `CVMetalTextureCache` 零拷贝 NV12 / BGRA 着色器渲染，支持 `Fit` / `Stretch` / `Original 1:1` 缩放与精确黑边坐标归一化。
- **低延迟音频 (`Audio/`)**：
  - `AudioPlayer.swift`：`AudioConverterRef` 解码 ADTS AAC-LC（48kHz 立体声）→ Float32 环形缓冲区 → `AVAudioEngine` + `AVAudioSourceNode` 播放。
- **原生输入与剪贴板 (`Input/`)**：
  - `KeyCodeMapper.swift` & `InputManager.swift`：完整 macOS `CGKeyCode` → W3C `KeyboardEvent.code` 映射、Windows 主机 `⌘ ↔ Ctrl` 键位互换、触控板高精度滚动与普通滚轮兼容、游戏鼠标相对位移指针锁定（`⌃⌥↩`）、失焦自动释放按键与远端光标形状同步。
  - `ClipboardSync.swift`：`NSPasteboard` 双向文本与 PNG 图片同步，内置 FNV-1a 64-bit 防回环哈希。
- **完全兼容 Remoter 协议 (`Network/`)**：
  - `RemoterConnection.swift`：基于 `URLSessionWebSocketTask`，支持自签名 TLS（`CN=Remoter`）、P-256 ECDH + AES-256-GCM 端到端加密、优先级发送队列（鼠标移动/滚轮合并 + 大文件背压）、2s 心跳与指数退避自动重连、局域网 `net_hint` 检测。
  - `DeviceStore.swift`：原子写入持久化至 `~/Library/Application Support/RemoterMacClient/devices.json`。

## 快捷键 (Shortcuts)

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl + Option + Return` (`⌃⌥↩`) | 切换游戏鼠标 / 指针锁定 (Pointer Lock) |
| `Ctrl + Command + F` (`⌃⌘F`) | 进入 / 退出原生全屏 |
| `Command + W` (`⌘W`) | 关闭当前窗口（桌面窗口将断开并返回连接页） |
| `Command + Q` (`⌘Q`) | 退出应用 |

## 构建与运行 (Build & Run)

需要 **macOS 14+** 与 **Swift 5.9+ / CommandLineTools**（无需安装完整 Xcode）。

```bash
cd Remoter-MacClient

# 1. 编译并运行单元测试
swift test

# 2. 打包为原生 .app（Debug）
./scripts/build-app.sh
open build/RemoterClient.app

# 3. 编译 Release 并安装到 /Applications
./scripts/build-app.sh --release --install
```
