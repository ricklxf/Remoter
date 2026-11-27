[🇨🇳 CN](README.md) | 🇺🇸 **EN**

---

# Remoter

A personal remote desktop tool for controlling Mac or Windows from any device.

- **Four clients & zero-copy native rendering** — alongside Electron / Web, includes zero-browser-overhead pure native clients for macOS (Swift/AppKit + VideoToolbox + Metal zero-copy) and Windows (.NET 10 + D3D11 + MediaFoundation + WASAPI + RawInput), with CAS sharpening and weak-network frame-drop protection
- **RTP media-track transport** — captured frames feed directly into libwebrtc's `RTCVideoSource`: native encoding + GCC congestion control + NACK/PLI retransmit/keyframe requests + jitter buffer, auto-negotiated over UDP, replacing the earlier hand-rolled DataChannel chunking scheme (Mac agent)
- **End-to-end encryption** — P-256 ECDH + AES-256-GCM, zero plaintext
- **LAN direct connect** — latency < 20ms
- **Cross-network** — WireGuard / VPN tunnel or self-hosted relay server
- **mac2 kept asking for Screen Recording: ad-hoc signing needs `-i com.remoter.agent`**: machines without the local "Remoter" certificate fall back to ad-hoc signing; without `-i` the signature is named `RemoterAgent-<hash>` and the designated requirement degrades to the content cdhash, which changes on every rebuild, so TCC treats each build as a new app and drops the Screen Recording / Accessibility grants. With `-i com.remoter.agent -r="designated => identifier …"` the app is matched by bundle ID. Machines with the "Remoter" certificate (mac4) are unaffected. The first build after the fix still needs one re-grant.
- **One controller per host; a new connection replaces the old one**: after a new session authenticates the server sends every older session `error` (`code=session_replaced`) and then closes it; clients recognise the code and do not auto-reconnect, otherwise the replaced side reconnects and kicks the other out, back and forth. Web/Electron and native macOS are updated; native Windows is updated but not compiled here.
- **Restart RemoterAgent on mac2 remotely with `pkill` only, never `open`**: mac2 has the LaunchAgent `com.remoter.agent` that relaunches it; a manual `open` leaves two processes and the second fails with `bind … Address already in use (errno 48)`.
- **`ProxyCommand connect` is not found in non-interactive SSH**: PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`; use the absolute Homebrew path `/opt/homebrew/bin/connect`.
- **Don't stream native 4K at 1.5-3 Mbps from a headless Mac over WireGuard**: the UDP rate control cut bitrate and lowered the ceiling at >=5% loss on the tunnel, while recovery needed <1% loss for 12s; this link sits at 0.5-5% loss all day, so the ceiling stayed pinned near the 1.5 Mbps floor (42 of 68 adapts that day). Now: when the user has not picked a resolution and the client is off-LAN, capture is limited to 2560 on the long side (`wan_res_cap`); back on the LAN, or with an explicit pick, no cap. Tunnel loss threshold 5%->7%, recovery probe now <2% loss for 8s.
- **Edge on Mac with no usable H.264 decoder config shows a blank screen**: `VideoDecoder.configure` rejected `avc3.640034` with `Unsupported configuration`, the decoder closed and every frame from the server was dropped. Init now probes relaxed configs in turn and, if none is supported, asks the server for JPEG; JPEG is drawn on a separate 2D canvas because the main canvas is already owned by WebGL and `getContext('2d')` would return null. If nothing is drawn 4s after connecting, a diagnostic line is shown at the bottom.
- **Merging wheel messages in the send layer must keep `px/py/isPrecise`**: `Connection.sendJson` coalesces consecutive wheel messages to avoid backlog but only summed `dx/dy` (whole notches), so the agent never received pixel deltas and one mouse notch under 100px did nothing. The symptom was `px=nil` in the server log. For this kind of bug, check the raw fields the server received before blaming the client.
- **The client's `net_hint lan=false` must not be overridden by server-side RTT inference**: WireGuard is direct P2P, private IPs, ~5ms RTT and often 0% loss, so it passed every `direct_lan_promoted` test and bypassed the tunnel cap and floor (all 46 sessions were promoted). Once the client reports it is off-LAN, the server no longer promotes.
- **The congestion guard must not trip on a single loss sample**: one 0.5s poll of 16-25% loss at 6ms RTT, then back to 0, made fps flap between 24 and target (307 times in two days). Loss now needs two consecutive polls; only RTT >= 250ms enters immediately.
- **Audio forwarding** — system audio encoded as AAC-LC, decoded and played via native hardware / WebCodecs on the client (off by default, toggle in the control menu)
- **Remote cursor shape sync** — remote cursor auto-hides during control while the local cursor renders with zero latency; shape (text beam, resize arrows, etc.) is polled and synced separately
- **Chinese IME pass-through** — all four clients (Web / Electron / Mac / Win) support local IME composition echo with snug candidate-bar alignment; only the final committed text is sent to the remote for injection
- **Multi-display** — pick which remote screen to view
- **Performance & latency HUD** — unified UU-style bottom-right multi-line translucent black stats HUD (40% black background, click-through) across all four clients showing live FPS, bitrate, RTT, and decode latency
- **Automatic reconnection** — WebRTC ICE renegotiates automatically on disconnect, no need to restart the whole session
- **File transfer** — bidirectional, saved to `~/Downloads` on the target machine
- **Clipboard sync** — bidirectional text + image auto-sync across all four clients (≤4MB PNG)
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
- Mac: `Remoter-MacServer/build/RemoterAgent.app`
- Win: `Remoter-WinServer/bin/Release/net8.0-windows/win-x64/publish/RemoterWin.exe` (with `web/` directory)

---

## Architecture

```
Remoter-MacServer/  Mac agent         Swift · ScreenCaptureKit · WebRTC (RTP) · Network.framework
Remoter-WinServer/  Windows agent     C# .NET 8 · DXGI Desktop Duplication · SendInput
                                      No WebRTC yet — video still goes over WebSocket
Remoter-Client/     Web/Electron      Electron + React + TypeScript
                                      Same codebase builds as a pure web app (no install needed)
Remoter-MacClient/  macOS native      Swift / AppKit · Metal · VideoToolbox · AudioToolbox (zero external SPM deps)
Remoter-WinClient/  Windows native    C# .NET 10 · D3D11 + DXGI 1.2 · MediaFoundation · WASAPI · RawInput
Remoter-Server/     Relay server      Node.js WebSocket + web client hosting (optional)
```

**Ports**

| Service | Port | Notes |
|---------|------|-------|
| Mac/Win WebSocket | 7788 | Agent main connection (override with `--port`) |
| Mac/Win Web client | 7799 | Static file server, auto-starts when `web/` exists |
| Relay server | 7789 | WebSocket relay + web client hosting |

---

## Mac Agent

**Requirements:** macOS 14 Sonoma or later (macOS 26 beta tested)

### Build

Requires Swift 5.9+ (Xcode Command Line Tools or full Xcode):

```bash
xcode-select --install   # first time only

cd Remoter-MacServer
bash scripts/build-app.sh            # debug build
bash scripts/build-app.sh --release  # release build (smaller & faster)
```

Output: `Remoter-MacServer/build/RemoterAgent.app`

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
open Remoter-MacServer/build/RemoterAgent.app                      # random PIN
open Remoter-MacServer/build/RemoterAgent.app --args --pin 123456  # fixed PIN
```

A `⬇` icon appears in the menu bar. Click it to see the **PIN**, **LAN WebSocket address**, and (if web client is embedded) the **web client URL**.

### Connection Logs

Stored at `~/Library/Logs/Remoter/connections.log`; open quickly via the menu bar's "Show log in Finder".

### Troubleshooting

- **macOS 15+ shows only the desktop wallpaper**: `CGDisplayCreateImage` returns a wallpaper-only frame when session auth is not approved. Fixed by migrating to `ScreenCaptureKit (SCStream)`, which triggers the correct session auth dialog.
- **PAM `pam_start("login")` fails for non-root processes**: the `"login"` service requires elevated privileges. Fixed by using `/usr/bin/dscl . -authonly` instead — no root needed, works for local accounts and Apple ID accounts.
- **Two permission dialogs appearing simultaneously**: fixed by requesting them sequentially — screen recording first (`await`), then accessibility.
- **`CVPixelBuffer` from SCStream can't be held across an async queue hop**: once the callback returns, the underlying IOSurface goes back into the pool and can be reused — dispatching to an encoder queue asynchronously reads data that's half-overwritten by the next frame (shows up as corruption at random positions). Must submit to VideoToolbox synchronously inside the callback.
- **The VideoToolbox encode completion callback must never do network I/O**: while the callback hasn't returned, VT's internal queue can't free a slot — one slow network send stalls every subsequent encode submission (framerate periodically collapses to single digits). Fixed by hopping sends onto a separate queue.
- **H.264 should use the High profile, not Baseline**: B-frames are already disabled via `AllowFrameReordering=false` for low latency; Baseline additionally gives up CABAC and 8x8 transform for no reason, costing 10-20% compression efficiency. WebCodecs support for High is excellent.
- **Keyframe interval extended from 2s to 10s**: a keyframe is 10-20x the size of a delta frame; one every 2s eats ~20% of bandwidth at the 2Mbps tier alone. On-demand `request_keyframe` (client asks after a drop / tab switch / decode overload) covers every recovery scenario.
- **The real signal for "client can't keep up decoding" is `kfReq`**: network metrics (fps/RTT) measure arrival, not decode — they look completely normal while the decoder is overloaded. Detect via WebCodecs `decodeQueueSize` backlog and recover by requesting a keyframe.
- **Split the quality auto-adaptation into two independent tracks**: fps follows the decode-overload signal (`kfReq`), bitrate follows send backpressure (`bpDrops`) — each steps up/down on its own, avoiding "one problem drags both down together".
- **Audio forwarding**: SCStream's `capturesAudio` captures system audio → AAC-LC + ADTS framing (self-describing, so the client's `AudioDecoder('mp4a.40.2')` needs no out-of-band handshake) → 0x03 binary frames. Off by default (bandwidth + privacy), toggle manually in the control menu.
- **Chinese input (IME)**: a canvas isn't an editable element, so the local input method can't compose text on it. A hidden 1px transparent textarea holds focus and hosts composition instead; `compositionend` sends the final committed text to the remote for injection via `keyboardSetUnicodeString`. During composition (`isComposing` / keyCode 229), neither `preventDefault` nor raw key forwarding happens.
- **Cursor shape sync**: the capture side hides the system cursor and the client renders its own locally (zero latency); shape is synced by polling `NSCursor.currentSystem` and sending a PNG + hotspot for the client to set as a CSS cursor. The cursor image must be re-rendered at point size — using the Retina 2x bitmap directly displays it at double size.
- **Multi-display**: mouse injection on a secondary display needs the `CGDisplayBounds` global-coordinate origin offset added — client coordinates are normalized relative to the *selected* display, but `CGEvent` wants global desktop coordinates.
- **RTP migration: feed `CVPixelBuffer` directly into `RTCVideoSource`**: captured frames no longer get encoded via VideoToolbox and chunked into 60KB DataChannel packets by hand. Instead `source.capturer(_:didCapture:)` hands them straight to libwebrtc's `RTCVideoSource` (`forScreenCast: true`), letting the stack own encoding, congestion control (GCC), retransmit/keyframe requests (NACK/PLI), and receive-side jitter buffering — replacing a whole batch of hand-rolled approximations (chunk reassembly, `bufferedAmount`-based backpressure drops, keyframe-storm mitigation). Our own reactive auto-quality ladder (fps/bitrate steps) now stands down on the RTP path so it doesn't fight GCC.
- **Picture goes blurry-to-sharp right after an RTP connection starts**: GCC doesn't know the link's real bandwidth up front, so it starts conservative and ramps up via RTCP feedback until it converges — this is intentional (it's exactly what avoids the old hand-rolled ladder's tendency to overshoot straight to max and stutter), not a bug. The same mechanism explains why fast scrolling or other high-motion content looks blurrier: the encoder has to keep up with the rate of change within a fixed bitrate budget, sacrificing sharpness, and recovers within a couple seconds once motion stops.
- **The media track can arrive before the client has subscribed to its event**: on loopback/LAN connections ICE negotiation can complete in single-digit milliseconds, so libwebrtc's `ontrack` may fire before the client component has even mounted and subscribed to the `media_stream` event. `Connection.emit()` has no replay mechanism, so that event is silently dropped — the picture stays completely blank while the latency/bitrate stats still show real RTP data flowing, which is easy to misdiagnose as "transport fine, just not rendering." Fixed by having `Connection` cache the most recently arrived `MediaStream` so a late subscriber can pick it up.
- **`track.muted` is the wrong signal for switching between the canvas and video element**: `ScreenCaptureKit` only produces a new frame when the screen content actually changes, so on a static screen (e.g. just reading, not scrolling) libwebrtc's video source — and therefore the track's `muted` flag — flips on and off constantly. Once the server switches to RTP it stops sending WS fallback frames, so the canvas underneath is frozen on whatever frame was on screen the moment RTP took over. Following `muted` to decide visibility swaps back to that stale frozen frame every time the screen goes briefly idle, then jumps forward again — showing up as the picture jumping between an old and a new frame. Fixed: once `<video>` receives a track, keep it visible and only fall back to canvas when the track truly ends (`onended`) — `<video>` already does the right thing on a stall (holds its last frame), so there's nothing to fix there.
- **"FPS drops to 0" on LAN is three different things**: (1) static screen — `ScreenCaptureKit` only emits frames on change, so 0 fps is accurate; the panel now says "画面静止" (idle); (2) stats gating — a blip in `pc.connectionState` made the panel fall back to counting WS binary frames (always 0 on an RTP session); it now only checks that the video track is live; (3) a real stall — GCC's bandwidth estimate collapsing. Compare `sent_5s` (captured frames) with `encoded` in `gcc_stats` in `connections.log`: capture at 57fps, encoder emitting 1-3fps, `target` falling from 5Mbps to 35-90Kbps and taking up to 125s to climb back. All 128 collapses happened with the LAN floor off — same-subnet Wi-Fi sits at 20-80ms RTT and never passes the RTT gate. Measured: at `target` >= 0.6Mbps the encoder still holds a median 52-57fps, below 300Kbps it stalls. Hence an RTT-independent 1Mbps base floor (revoking the 12Mbps LAN floor now falls back to it instead of clearing the floor).
- **`sent_5s` fps is a screen-change rate, not smoothness**: moving the mouse produces no frames (the cursor is rendered client-side) and typing only a few per second. Low `sent_5s` during input does not mean a stall — check whether the `encoded` delta in `gcc_stats` keeps up with `sent`.
- **Scrolling "didn't track the hand" for months because only fps and latency were being measured**: the real cause was the client rounding each wheel delta with `Math.round(delta/120)` into whole lines — anything under 60px (most touchpad / smooth-wheel output) became zero, while fps and latency stayed healthy. The client now accumulates raw pixels (remainder carried, dominant axis only); the Mac agent injects `.pixel`-unit events, the Windows agent scales 100px = 120 into fine-grained wheel data. When agent-side numbers keep coming back healthy, read the input-event code instead of adding more transport diagnostics.
- **The bitrate floor must not be revoked by a single RTT sample**: `currentRoundTripTime` only updates on STUN checks (every few seconds); one 49ms sample with zero loss revoked the 12Mbps floor, GCC restarted from 1.4Mbps and scrolling turned to mush. Revocation now needs receiver-reported loss, one very high RTT, or two new high samples in a row, followed by a 30s cooldown. The `client_rx` line the client reports every 2s (frames received / loss / freezes / jitter buffer) is the direct way to tell a network stall from an agent-side one.
- **Privacy curtain: rebuild capture, and make the overlay ignore the mouse**: the overlay windows are created after the stream starts, but `SCContentFilter` is computed once at stream start, so without a rebuild the remote side sees the curtain; the overlay sits above the screen-saver level, so without `ignoresMouseEvents` the remote's injected clicks/scrolls land on it. The virtual display and the curtain are process-wide singletons — only the last session closing may tear them down.
- **The tunnel bitrate cap must not be `max(cap, requested)`**: auto mode requests 25M as soon as RTP is up, so that expression is no cap at all and WireGuard overshoots and loses packets again. Off-LAN with auto bitrate holds a 10Mbps ceiling; manual picks are not capped.
- **The smooth-scroll engine must drop the opposite-direction backlog on reversal**: a fast spin queues hundreds of pixels of target distance; netting against it leaves the page travelling the old way for a while. An animation that finishes in a single tick also needs its ended phase.
- **Auto fps must not exceed the captured display's refresh rate**: climbing to 120fps on a 60Hz panel only deepens the capture queue.
- **The "occasional stutter" over the public path was Wi-Fi jitter, not packet loss**: with the Windows controller on Wi-Fi, `ping -l 1200` showed 0% loss but latency spikes up to 187ms. A 1200B video packet that queues and arrives late is treated as lost by the UDP receiver (frame timeout 220ms / keyframe timeout 350ms, then retransmit and keyframe requests). 32B pings looked perfect, so small-packet pings alone mislead. Prefer wired or 5GHz and turn off NIC power saving; on the server side we can only reduce bursts (next three items).
- **WAN bitrate cap 12Mbps -> 8Mbps (`Session.wanMaxBitrateBps`)**: VideoToolbox `DataRateLimits` is `[burstBytes, 1s]` and VT drops frames above it, so fps tracks bitrate. A keyframe reached ~164KB at 12Mbps and, squeezed into Wi-Fi at once, caused jitter. At 8Mbps keyframes are smaller with no obvious quality loss.
- **Widen the encoder burst while scrolling, then give it back**: scrolling changes large areas continuously and the 1.35 burst factor made VT drop frames. `setScrollBoost` temporarily raises it to 1.8 on WAN when loss < 5%, and restores it 1.2s after the last scroll.
- **The bandwidth saver (`wan_bg_saver`) must not flap on/off**: it drops to 20fps/1.5Mbps after 12s idle, but any mouse move restored it, so it oscillated. Entering now needs "idle for another 1.5s" (`wanBgSaverArmedAt`); restore goes to 30fps first and steps back to the original fps after 4s.
- **Our own bug that pinned fps at 30**: the gentle restore overwrote the saved fps with the just-restored 30, and the step-up depended on a stale loss guard. Now `wanBgBestFps` is tracked separately and step-up only needs "no loss guard, loss < 8%, still at the starting tier".
- **Read keyframe size from the log, don't guess**: we once suspected 180KB keyframes; measured were 20-98KB (164KB at 12Mbps). `keyframe_sent bytes=... frags=... backlog=...` is now a permanent log: `grep keyframe_sent ~/Library/Logs/Remoter/connections.log`.
- **UU Remote has no "small packet" trick either**: `libstreamer.dylib` is libwebrtc (FlexFEC, NACK, pacer, trendline BWE) + QUIC with the same ~1200B RTP payload; it wins on more mature congestion control, not smaller packets.
- **Images copied in WeChat can't be read by the agent**: WeChat writes "copy image" as a `file-url` into its own sandbox (`~/Library/Containers/com.tencent.xinWeChat/...`), which RemoterAgent can't open. The client download then waits forever: no prompt appears, nothing is pasted, and the log has no error. The agent now checks with `canReadFile` before sending, skips unreadable files and sends the pasteboard image data instead, logging `clipboard_files_unreadable`; `send_file_unreadable` replies a `file_unreadable` error to the client.
- **Clipboard text must not be de-duplicated by content alone**: copying the same text again changes nothing in the content, so it was treated as if it never happened and the controller kept whatever was copied in between (the log had no `clipboard_reverse_sent` for that copy). `lastSentClipboardTextChangeCount` is now tracked: same content but a new `changeCount` is resent. Repeated copies of the same text within 3s count once, and the swallowed copy's count is remembered so it isn't sent later.
- **Image sync limit 4MB -> 10MB**: Retina screenshots often exceed 4MB, and over the limit it was silently dropped.
- **Clean up temporary diagnostics in pairs**: the `scroll_gesture`, `frame_after_scroll`, `text_input_received`, `client_rx` and `gcc_stats` logs were removed; for `gcc_stats` only the log line went, the polling stays because `evaluateMinBitrateFloor / CongestionGuard / LossCap` run on it.

---

## Windows Agent

**Requirements:** Windows 10 1803+ x64, .NET 8 Runtime

Screen capture uses **DXGI Desktop Duplication API** (GPU-side, < 2ms/frame). Input injection uses **SendInput** Win32 API. Video still goes over WebSocket for now — no WebRTC/RTP implementation yet.

### Build

Requires .NET 8 SDK:

```bash
cd Remoter-WinServer
dotnet publish -r win-x64 -c Release -p:PublishSingleFile=true --self-contained
```

Output: `RemoterWin.exe` (single file, no runtime install needed)

### Launch

```
RemoterWin.exe                     # random PIN, port 7788
RemoterWin.exe --pin 123456        # fixed PIN
RemoterWin.exe --port 7789         # custom port
```

### Logs

All logs (`remoter.log`, `connections.log`) are stored in `%LOCALAPPDATA%\Remoter\logs\`; click "打开日志" in the main window or "打开日志文件夹" in the tray menu to open it.

---

## Controller

Available in four forms: **Electron / Web** from a shared React codebase, plus zero-browser-overhead pure native clients for **macOS** and **Windows**. All four clients share the unified UU-style bottom-right multi-line translucent black performance HUD, local IME composition echo with snug candidate alignment, remote cursor hiding, and bidirectional clipboard sync.

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

### C. macOS Pure Native Client (`Remoter-MacClient`)

**Requirements:** macOS 14 Sonoma+, Swift 5.9+ (CommandLineTools only, zero external SPM dependencies)

Built with **Swift / AppKit + VideoToolbox hardware decoding + Metal zero-copy rendering + AudioToolbox / AVAudioEngine**. Supports H.264 / H.265, CAS sharpening, 4:4:4/HDR protocol, precision trackpad scrolling, game-mouse pointer lock (`⌃⌥↩`), and local IME composition echo. See [Remoter-MacClient/README.md](Remoter-MacClient/README.md) for details.

```bash
cd Remoter-MacClient
swift test                                  # build and run unit tests
./scripts/build-app.sh --release            # build Release .app (outputs to build/RemoterClient.app)
./scripts/build-app.sh --release --install  # build Release and install to /Applications
```

You can also double-click `build.command` or `update.command` to build/update and launch in one step.

### D. Windows Pure Native Client (`Remoter-WinClient`)

**Requirements:** Windows 10/11 x64, .NET 10 SDK (`net10.0-windows`)

Built with **C# .NET 10 + Direct3D 11 / DXGI 1.2 Flip-Model + Media Foundation video/audio decoding + WASAPI + Win32 RawInput**. Supports zero-copy GPU shader rendering, CAS sharpening, high-polling-rate game mouse (`Ctrl+Alt+Enter`), fine-grained touchpad scrolling, and local IME composition echo. See [Remoter-WinClient/README.md](Remoter-WinClient/README.md) for details.

```powershell
cd Remoter-WinClient
# Option 1: double-click build.bat (build, publish to publish\, and launch) or update.bat (git pull + build)
# Option 2: publish from CLI
dotnet publish -c Release -r win-x64 --self-contained
```

### How to Connect

1. Open the controller (desktop app or browser)
2. Choose **Direct (LAN)**, enter the agent address: `ws://192.168.1.x:7788`
3. Enter the **PIN** (copy from the agent's menu bar) or username/password
4. Click Connect and wait for the screen to appear

### Troubleshooting

- **Electron has no native H.265/HEVC decode support**: stock Electron builds ship without an HEVC software decoder (patent licensing) and without the platform hardware-decode hook (`enable_platform_hevc`) compiled in — regardless of what the OS/GPU can actually do, `VideoDecoder.isConfigSupported` always reports unsupported. This is a known Electron limitation, not a bug in this project; a regular browser (especially official Chrome) isn't affected. The codec selector in the quality menu only shows up when support is actually detected.
- **The IME candidate window's position can't auto-adapt to resolution — it needs manual calibration**: it anchors to the caret position of the hidden staging textarea and grows rightward from there; the browser exposes neither the popup's actual width nor the remote's input-cursor coordinates, so there's no way to compute a correct position automatically. The same pixel offset also looks right on one machine and wrong on another with a different resolution/OS scale factor. Fixed by making the offset drag-adjustable instead (`utils/imeOffset.ts`, persisted to local `localStorage`): once the composition echo box appears while typing, just drag it to line up with the real candidate window and let go — a new machine needs a one-time re-drag.
- **Images copied in DingTalk paste with only the top half**: DingTalk's clipboard has only `Bitmap`/`DeviceIndependentBitmap`/`Format17` (DIBV5) and `FileDrop`/`FileName` — **no `PNG`**. `Clipboard.GetImage()` converts that alpha-carrying bitmap with the lower half pure white (Paint reads DIBV5 and shows it whole). The agent logged the same image size, so the transfer lost nothing; the source read was wrong. When the clipboard has both a bitmap and a single existing image file, the client now reads the original file bytes (png as-is, jpg/bmp/gif converted to png); if the path doesn't exist it no longer gives up and falls back to the bitmap. If another app gets cut in half too, have the user run `[Windows.Forms.Clipboard]::GetDataObject().GetFormats()` to see the formats before deciding which to read.
- **Clicking a taskbar window button only beeps and the window doesn't come up**: Windows refuses to bring that window to the foreground. We first suspected the disconnect-notice `MessageBox` had disabled the main window; the real cause was a fullscreen/exclusive app on another monitor holding the foreground and limiting other programs from activating windows. Workarounds: click an empty spot on the target monitor first, switch that app to borderless windowed, or use Alt+Tab.
- **The Windows portable exe needs a fixed unpack directory name**: `electron-builder`'s `portable` target hashes the unpack directory name from the packaged filename (which includes the version) by default, so every version bump extracts to a new path. Windows Firewall's allow-rule is keyed on the executable's path, so a new path is treated as an unrecognized new program every time — for a "rebuild constantly while fixing bugs" workflow, that means a firewall prompt on almost every launch. Fixed by pinning `portable.unpackDirName` to a constant in `electron-builder.yml`: no matter how many new versions get built, they all extract to the same path, so the firewall only needs to grant access once.

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
bash Remoter-MacServer/scripts/cloudflare-tunnel.sh
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
