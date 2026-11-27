🇨🇳 **CN** | [🇺🇸 EN](README_EN.md)

---

# Remoter

个人远程桌面工具，支持从任意设备远程控制 Mac 或 Windows。

- **四端覆盖 & 原生零拷贝渲染**：除 Electron / 纯网页端外，提供零浏览器开销的 macOS 纯原生端（Swift/AppKit + VideoToolbox + Metal 零拷贝）与 Windows 纯原生端（.NET 10 + D3D11 + MediaFoundation + WASAPI + RawInput），支持 CAS 锐化与弱网快进慢出降帧保护
- **RTP 媒体轨道传输**：屏幕帧直接喂给 libwebrtc 的 `RTCVideoSource`，原生编码 + GCC 拥塞控制 + NACK/PLI 丢包重传/关键帧请求 + 抖动缓冲，自动协商 UDP 传输，取代早期手写的 DataChannel 分片方案（Mac 端）
- **端到端加密**：P-256 ECDH + AES-256-GCM，零明文传输
- **局域网直连**：延迟 < 20ms
- **跨网络**：支持 WireGuard / VPN 穿透，或自建中继服务器
- **音频转发**：系统声音 AAC-LC 编码转发，客户端硬件/WebCodecs 解码播放（默认关闭，控制菜单手动开启）
- **远端光标形状同步**：控制时自动隐藏被控端光标，本地零延迟渲染，形状轮询同步（文本光标、调整大小箭头等）
- **中文输入法（IME）透传**：四端（Web / Electron / Mac / Win）均支持本地输入法组词回显与紧贴候选框对齐，只有确定的文字才发送到远端注入
- **多显示器**：可选择远程哪块屏幕
- **性能与延迟浮窗**：四端统一仿 UU 风格右下角多行半透明黑色性能浮窗（40% 透明黑底、点击穿透），实时展示帧率、码率、网络 RTT 与解码耗时
- **断线自动重协商**：WebRTC ICE 断开后自动重建，不需要重连整个会话
- **文件传输**：双向发送文件，保存到目标机 `~/Downloads`
- **剪贴板同步**：四端双向文本 + 图片自动同步（≤4MB PNG）
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
- Mac：`Remoter-MacServer/build/RemoterAgent.app`
- Win：`Remoter-WinServer/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe`（含 `web/` 子目录）

---

## 架构

```
Remoter-MacServer/  Mac 被控端      Swift · ScreenCaptureKit · WebRTC (RTP) · Network.framework
Remoter-WinServer/  Windows 被控端  C# .NET 8 · DXGI Desktop Duplication · SendInput
                                    暂无 WebRTC 实现，视频走 WebSocket 传输
Remoter-Client/     通用控制端      Electron + React + TypeScript
                                    同一套代码也能构建为纯网页版（无需安装）
Remoter-MacClient/  Mac 纯原生端    Swift / AppKit · Metal · VideoToolbox · AudioToolbox（零外部 SPM 依赖）
Remoter-WinClient/  Win 纯原生端    C# .NET 10 · D3D11 + DXGI 1.2 · MediaFoundation · WASAPI · RawInput
Remoter-Server/     公网中继服务器  Node.js WebSocket + Web 客户端托管（可选）
```

**端口一览**

| 服务 | 端口 | 说明 |
|------|------|------|
| Mac/Win WebSocket | 7788 | 被控端主连接（可 `--port` 覆盖） |
| Mac/Win Web 客户端 | 7799 | 静态文件服务，有 `web/` 时自动开启 |
| 中继服务器 | 7789 | WebSocket 中转 + Web 客户端托管 |

---

## Mac 被控端

**系统要求：** macOS 14 Sonoma 或更高（macOS 26 beta 已测试）

### 编译 & 打包

需要 Swift 5.9+（Xcode Command Line Tools 或完整 Xcode）：

```bash
xcode-select --install   # 仅首次

cd Remoter-MacServer
bash scripts/build-app.sh            # debug 包
bash scripts/build-app.sh --release  # release 包（更小更快）
```

产物：`Remoter-MacServer/build/RemoterAgent.app`

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
open Remoter-MacServer/build/RemoterAgent.app                      # 随机生成 PIN
open Remoter-MacServer/build/RemoterAgent.app --args --pin 123456  # 指定 PIN
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
- **内网"帧率掉 0"其实是三件事，别混着查**：① 画面静止——`ScreenCaptureKit` 只在画面变化时出帧，静止时 0 fps 是如实反映，面板现在显示"画面静止"；② 统计门控——`pc.connectionState` 抖一下面板就回退去数 WS 二进制帧（RTP 会话里恒为 0），现在只看视频轨道是否存活；③ 真卡顿——GCC 带宽估计崩溃。`connections.log` 里对照 `sent_5s`（采集帧数）和 `gcc_stats` 的 `encoded`：采集 57fps、编码只出 1~3fps、`target` 从 5Mbps 砸到 35~90Kbps，最长 125 秒才爬回来。128 次崩溃全部发生在局域网保底关闭时——同网段 Wi‑Fi 的 RTT 常年 20~80ms，过不了 RTT 门槛。实测 `target` ≥ 0.6Mbps 编码帧率中位数仍有 52~57，低于 300Kbps 才停摆，所以加了不依赖 RTT 的 1Mbps 基础保底（局域网 12Mbps 保底撤销时回落到它，而不是清空）。
- **`sent_5s` 的 fps 是"画面变化率"不是"流畅度"**：移动鼠标不产生新帧（光标由客户端本地渲染），打字每秒只有几帧。有输入时 `sent_5s` 很低不代表卡——要看 `gcc_stats` 的 `encoded` 增量是否跟得上 `sent`。
- **滚动"不跟手"查了几个月没查到，因为一直在量帧率和延迟**：真正的原因是滚轮增量在客户端被 `Math.round(delta/120)` 取整成整行，小于 60px 的增量（触控板/平滑滚轮的大部分输出）直接归零，帧率和延迟全程正常所以怎么量都"没问题"。现在客户端累计原始像素（余数跨次保留、只保留主轴），Mac 端按 `.pixel` 单位注入，Windows 端按 100px=120 换算成细粒度滚轮值。被控端数据反复显示健康时，该去读输入事件本身的代码，而不是继续加传输侧诊断。
- **码率保底不能被单次 RTT 样本撤销**：`currentRoundTripTime` 只在 STUN 检查时更新（几秒一次），一个零丢包的 49ms 样本就把 12Mbps 保底撤了，GCC 从 1.4Mbps 重爬，滚动糊成一片。撤销改看接收端丢包、单次极高 RTT 或连续两个新样本偏高，撤销后 30 秒冷却。客户端每 2 秒回传的 `client_rx`（收帧/丢包/冻结/抖动缓冲）是判断"卡在网络还是卡在被控端"的直接依据。
- **防窥屏要先重建采集、遮罩要忽略鼠标**：遮罩窗口是开启后才创建的，而 `SCContentFilter` 只在采集启动时算一次，不重建的话远端看到的是遮罩；遮罩层级在屏保之上，不设 `ignoresMouseEvents` 的话远端注入的点击/滚轮会落在遮罩上。虚拟屏和防窥屏是进程级单例，只有最后一个会话关闭时才能销毁。
- **隧道码率上限不能写成 `max(上限, 请求值)`**：自动档在 RTP 就绪时请求 25M，这样写等于没有上限，WireGuard 上又会冲过头丢包。非局域网且码率为自动档时固定 10Mbps 上限，手动选择不限制。
- **mac2 反复弹屏幕录制授权框：ad-hoc 签名必须带 `-i com.remoter.agent`**：没有本地 "Remoter" 证书的机器回退 ad-hoc 签名，若不指定 `-i`，签名标识成 `RemoterAgent-<哈希>`，指定要求退化成内容 cdhash，每次重建都变，TCC 把每次构建当新应用，屏幕录制/辅助功能授权失效。改为 `-i com.remoter.agent -r="designated => identifier …"` 后按 Bundle ID 识别。有 "Remoter" 证书的机器（mac4）不受影响。修复后的第一次构建仍需重新授权一次。
- **同一台被控端只允许一台电脑连接，新连接挤掉旧连接**：服务端在新会话认证后，对所有旧会话先发 `error`（`code=session_replaced`）再关闭；客户端识别该 code 后不再自动重连，否则被挤掉的一方会重连再把对方挤掉，两边反复抢。Web/Electron、macOS 原生已改，Windows 原生已改但未编译验证。
- **远程重启 mac2 的 RemoterAgent 只能 `pkill`，不要再 `open`**：mac2 有 LaunchAgent `com.remoter.agent` 会自动拉起，再手动 `open` 会出现两个进程，第二个报 `bind … Address already in use (errno 48)`。
- **远程（非交互）SSH 里 `ProxyCommand connect` 找不到命令**：PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，Homebrew 的 `connect` 要写绝对路径 `/opt/homebrew/bin/connect`。
- **公网（WireGuard）访问 4K 无头机时，不能用原生 4K 配 1.5~3Mbps**：UDP 码控在隧道上丢包 ≥5% 就降码率并压低上限，而恢复要求丢包 <1% 持续 12 秒，这条链路丢包常年 0.5%~5%，上限长期卡在 1.5Mbps 底部（当天 68 次调整里 42 次）。现在：分辨率未被用户手动选择且客户端不在局域网时，采集长边限制为 2560（`wan_res_cap`），回到局域网或手动选择分辨率则不限制；隧道丢包阈值 5%→7%，恢复探测改为丢包 <2%、8 秒。
- **Edge（Mac）没有可用的 H.264 解码配置会整屏无画面**：`VideoDecoder.configure` 对 `avc3.640034` 报 `Unsupported configuration`，解码器直接关闭，服务端发来的帧全被丢。现在初始化时依次探测放宽的配置，仍不支持就让服务端改发 JPEG；JPEG 画到独立的 2D canvas，因为主 canvas 已被 WebGL 占用，`getContext('2d')` 会返回 null。连接 4 秒仍无画面时底部会显示诊断行。
- **发送层合并滚轮消息时必须保留 `px/py/isPrecise`**：`Connection.sendJson` 为防积压合并连续滚轮，只累加了 `dx/dy`（整格），被控端永远收不到像素值，鼠标滚一格不够 100px 就不动。现象是服务端日志里 `px=nil`。排查这类问题先看服务端收到的原始字段，再查客户端。
- **客户端的 `net_hint lan=false` 不能被服务端 RTT 推断覆盖**：WireGuard 是直连 P2P、私网 IP、RTT 约 5ms、常 0 丢包，通过了 `direct_lan_promoted` 的全部条件，结果隧道上限和保底被绕开（46 个会话全部被提升）。客户端上报离开局域网后，服务端不再提升。
- **拥塞保护不能被单次丢包采样触发**：隧道上有一次 0.5s 内 16~25% 丢包、RTT 6ms、随后回到 0 的突发，单样本触发会让帧率在 24 与目标之间来回切（两天 307 次）。现在丢包必须连续两次采样才进入，只有 RTT≥250ms 才立即进入。
- **平滑滚动引擎换向要清掉反方向的欠账**：快速转滚轮会积压几百像素的目标距离，换向只做减法的话页面还会往老方向走一段；只有一个 tick 就走完的动画也要补发 ended 相位。
- **自动档帧率不能超过被采集显示器的刷新率**：60Hz 屏上爬到 120fps 只会白白加深采集队列。
- **公网"偶发卡顿"的根因是 Wi‑Fi 抖动，不是丢包**：Windows 控制端走 Wi‑Fi 时，`ping -l 1200` 出现 0 丢包但最高 187ms 的延迟尖峰，1200B 的视频包排队后晚到，被 UDP 接收端按"丢失"处理（帧超时 220ms / 关键帧超时 350ms，再触发重传和关键帧请求）。32B 小包 ping 完全正常，所以只看小包 ping 会误判链路没问题。优先换有线或 5GHz，并关掉网卡省电；服务端侧只能降低突发（见下面三条）。
- **公网码率上限 12Mbps → 8Mbps（`Session.wanMaxBitrateBps`）**：VideoToolbox 的 `DataRateLimits` 按 `[突发字节数, 1s]` 设置，VT 超出就直接丢帧，帧率随码率走。关键帧在 12Mbps 时最大约 164KB，一口气挤进 Wi‑Fi 就会抖。降到 8Mbps 后关键帧更小，画质损失不明显。
- **滚动时放宽编码器突发上限，滚完立刻收回**：滚动是持续大面积变化，突发系数 1.35 会让 VT 丢帧导致不跟手；`setScrollBoost` 在公网且丢包 <5% 时临时提到 1.8，1.2s 无新滚动即恢复。
- **省流模式（`wan_bg_saver`）不能一进一出地抖**：空闲 12s 才降到 20fps/1.5Mbps，但鼠标一动就恢复，反复开关会让码控来回震荡。现在进入前要"连续空闲再多等 1.5s"（`wanBgSaverArmedAt`），恢复时先回 30fps，4s 后再逐步爬回原帧率。
- **帧率被锁死在 30fps 的自己人 bug**：温和恢复把"保存的帧率"覆盖成了刚恢复的 30，且升回条件依赖一个过期的丢包保护，导致一直升不回去。现在单独记 `wanBgBestFps`，升回条件放宽为"无丢包保护、丢包 <8%、当前仍是起步档"。
- **关键帧大小要靠日志看，别靠猜**：曾经怀疑关键帧有 180KB，实测 20~98KB（12Mbps 时 164KB）。现在常驻记录 `keyframe_sent bytes=… frags=… backlog=…`，排查卡顿先 `grep keyframe_sent ~/Library/Logs/Remoter/connections.log`。
- **UU 远程也没有"小包"秘诀**：`libstreamer.dylib` 里是 libwebrtc（FlexFEC、NACK、pacer、趋势线 BWE）+ QUIC，RTP 载荷同样约 1200B，它靠的是更成熟的拥塞控制，不是改小包。
- **微信里复制的图片，被控端读不到文件**：微信把"复制图片"写成指向自己沙盒（`~/Library/Containers/com.tencent.xinWeChat/…`）里文件的 `file-url`，RemoterAgent 无权打开，客户端下载会无限等待，表现为"两个提示都没弹、什么都没粘过去"，日志里也没有错误。现在发送前用 `canReadFile` 检查，读不了就跳过文件、改发剪贴板里的图片数据，并记 `clipboard_files_unreadable`；`send_file_unreadable` 会回 `file_unreadable` 错误给客户端。
- **剪贴板文本不能只按"内容相同"去重**：同一段文字再复制一次，内容没变就被当成没发生，控制端剪贴板里留着中间复制过的别的东西，粘出来对不上（日志里该次复制完全没有 `clipboard_reverse_sent`）。现在额外记录 `lastSentClipboardTextChangeCount`，内容相同但 `changeCount` 变了就重发；同时 3 秒内连续重复复制相同文本只算一次，吞掉的那次也会记下计数，不会事后补发。
- **图片同步上限 4MB → 10MB**：Retina 截图经常超过 4MB，超限时同样是静默不发。
- **临时诊断日志要成对清理**：排查时加的 `scroll_gesture`、`frame_after_scroll`、`text_input_received`、`client_rx`、`gcc_stats` 已删除；`gcc_stats` 只删了日志那一行，轮询要保留——`evaluateMinBitrateFloor / CongestionGuard / LossCap` 靠它驱动。

---

## Windows 被控端

**系统要求：** Windows 10 1803+ x64，.NET 8 Runtime

画面采集使用 **DXGI Desktop Duplication API**（GPU 侧捕获，延迟 < 2ms/帧），输入注入使用 **SendInput** Win32 API。视频传输目前仍走 WebSocket（尚无 WebRTC/RTP 实现）。

### 编译

需要 .NET 8 SDK：

```bash
cd Remoter-WinServer
dotnet publish -r win-x64 -c Release -p:PublishSingleFile=true --self-contained
```

产物：`Remoter-WinServer/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe`（单文件，无需安装运行时）

### 启动

```
RemoterWin.exe                     # 随机生成 PIN，端口 7788
RemoterWin.exe --pin 123456        # 指定 PIN
RemoterWin.exe --port 7789         # 指定端口
```

### 日志目录

所有日志（`remoter.log`、`connections.log`）统一存储于 `%LOCALAPPDATA%\Remoter\logs\`，可点击主界面「打开日志」或托盘菜单「打开日志文件夹」一键打开。

---

## 控制端

提供四种形态：基于同一套 React 代码的 **Electron / Web 端**，以及零浏览器开销的 **macOS / Windows 纯原生客户端**。四端共享统一的右下角仿 UU 多行半透明黑色性能浮窗、本地 IME 组词回显与紧贴候选框对齐、双向剪贴板同步与远端光标隐藏。

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

### C. macOS 纯原生客户端（`Remoter-MacClient`）

**系统要求：** macOS 14 Sonoma+，Swift 5.9+（仅需 CommandLineTools，零外部 SPM 依赖）

基于 **Swift / AppKit + VideoToolbox 硬件解码 + Metal 零拷贝渲染 + AudioToolbox / AVAudioEngine** 构建，支持 H.264 / H.265、CAS 锐化、4:4:4/HDR 协议、原生触控板高精度滚动、游戏鼠标指针锁定（`⌃⌥↩`）与本地 IME 组词上屏。详见 [Remoter-MacClient/README.md](Remoter-MacClient/README.md)。

```bash
cd Remoter-MacClient
swift test                            # 编译并运行单元测试
./scripts/build-app.sh --release      # 打包 Release 原生 .app（输出至 build/RemoterClient.app）
./scripts/build-app.sh --release --install  # 编译并安装到 /Applications
```

也可直接双击目录内的 `build.command` / `update.command` 一键构建或拉取更新并启动。

### D. Windows 纯原生客户端（`Remoter-WinClient`）

**系统要求：** Windows 10/11 x64，.NET 10 SDK（`net10.0-windows`）

基于 **C# .NET 10 + Direct3D 11 / DXGI 1.2 Flip-Model 渲染 + Media Foundation 视频/音频解码 + WASAPI + Win32 RawInput** 构建，支持零拷贝 GPU 着色器渲染、CAS 锐化、高回报率游戏鼠标（`Ctrl+Alt+Enter`）、触控板细粒度滚动与本地 IME 组词上屏。详见 [Remoter-WinClient/README.md](Remoter-WinClient/README.md)。

```powershell
cd Remoter-WinClient
# 方式一：双击 build.bat（自动编译、发布单文件至 publish\ 并启动）或 update.bat（拉取代码并构建）
# 方式二：命令行手动发布
dotnet publish -c Release -r win-x64 --self-contained
```

### 连接步骤

1. 打开控制端（桌面 app 或浏览器）
2. 选择「直连（局域网）」，填入被控端地址：`ws://192.168.1.x:7788`
3. 输入 **PIN 码**（从被控端菜单栏复制）或账号密码
4. 点击连接，等待画面出现

### 踩坑记录

- **Electron 天然不支持 H.265/HEVC 解码**：标准 Electron 发行版不带 HEVC 软解码器（专利授权问题），硬解钩子（`enable_platform_hevc`）也没有编译进标准构建，不论系统/显卡实际是否支持硬解，`VideoDecoder.isConfigSupported` 探测永远返回不支持——这是 Electron 已知限制，不是本项目代码问题。浏览器（尤其 Chrome 官方版）不受此限制。画质菜单里的编码方式选项因此只在探测到支持时才显示。
- **IME 候选框位置不能自动适配分辨率，只能手动校准**：候选框以本地暂存用的隐形 textarea 光标位置为锚点向右展开，浏览器既不暴露候选框实际宽度，也拿不到远端输入光标坐标，做不到自动精确定位；不同机器的分辨率/系统缩放比例不同，同一个像素偏移量在别的机器上位置就会偏。做法是把偏移量做成可拖拽调节（`utils/imeOffset.ts`，存在本机 `localStorage`）：打字出现候选词回显框后，直接按住它拖到跟系统候选框对齐的位置松手即可，换机器需要重新拖一次。
- **钉钉里复制的图片粘过去只有上半截**：钉钉剪贴板里只有 `Bitmap`/`DeviceIndependentBitmap`/`Format17`（DIBV5）和 `FileDrop`/`FileName`，**没有 `PNG`**。`Clipboard.GetImage()` 对这份带透明通道的位图转换出来下半部分是纯白（画图读 DIBV5 却是完整的）。被控端日志里图片大小一致，说明传输没丢数据，是源头读错。现在剪贴板同时有位图和单个真实存在的图片文件时，直接读原图文件字节发送（png 原样、jpg/bmp/gif 转 png）；文件路径不存在时也不再直接放弃，继续按位图处理。若别的应用也截半，先让用户跑 `[Windows.Forms.Clipboard]::GetDataObject().GetFormats()` 看剪贴板格式，再决定读哪一种。
- **点任务栏窗口按钮只响一声、窗口不弹出**：Windows 拒绝把该窗口切到前台。一度怀疑是断开提示的 `MessageBox` 模态框把主窗口禁用了，实际原因是另一块屏幕上开着全屏/独占应用，占着前台、限制别的程序激活窗口。规避：先点一下目标屏幕空白处、把全屏应用改成无边框窗口化，或用 Alt+Tab 切换。
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
bash Remoter-MacServer/scripts/cloudflare-tunnel.sh
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
