[🇨🇳 CN](README.md) | 🇺🇸 **EN**

---

# Remoter

A personal remote desktop tool for controlling Mac or Windows from any device.

- **RTP media-track transport** — captured frames feed directly into libwebrtc's `RTCVideoSource`: native encoding + GCC congestion control + NACK/PLI retransmit/keyframe requests + jitter buffer, auto-negotiated over UDP, replacing the earlier hand-rolled DataChannel chunking scheme (Mac agent)
- **End-to-end encryption** — P-256 ECDH + AES-256-GCM, zero plaintext
- **LAN direct connect** — latency < 20ms
- **Cross-network** — WireGuard / VPN tunnel or self-hosted relay server
- **Audio forwarding** — system audio encoded as AAC-LC, decoded and played via WebCodecs on the client (off by default, toggle in the control menu)
- **Remote cursor shape sync** — cursor position renders locally with zero latency; shape (text beam, resize arrows, etc.) is polled and synced separately
- **Chinese IME pass-through** — local input method composes/selects candidates normally; only the final committed text is sent to the remote for injection
- **Multi-display** — pick which remote screen to view
- **Latency breakdown** — encode / network / decode timings shown separately
- **Automatic reconnection** — WebRTC ICE renegotiates automatically on disconnect, no need to restart the whole session
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
Remoter-Mac/        Mac agent       Swift · ScreenCaptureKit · WebRTC (RTP) · Network.framework
Remoter-Win/        Windows agent   C# .NET 8 · DXGI Desktop Duplication · SendInput
                    No WebRTC yet — video still goes over WebSocket
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

---

## Windows Agent

**Requirements:** Windows 10 1803+ x64, .NET 8 Runtime

Screen capture uses **DXGI Desktop Duplication API** (GPU-side, < 2ms/frame). Input injection uses **SendInput** Win32 API. Video still goes over WebSocket for now — no WebRTC/RTP implementation yet.

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

### Troubleshooting

- **Electron has no native H.265/HEVC decode support**: stock Electron builds ship without an HEVC software decoder (patent licensing) and without the platform hardware-decode hook (`enable_platform_hevc`) compiled in — regardless of what the OS/GPU can actually do, `VideoDecoder.isConfigSupported` always reports unsupported. This is a known Electron limitation, not a bug in this project; a regular browser (especially official Chrome) isn't affected. The codec selector in the quality menu only shows up when support is actually detected.
- **The IME candidate window's position can't auto-adapt to resolution — it needs manual calibration**: it anchors to the caret position of the hidden staging textarea and grows rightward from there; the browser exposes neither the popup's actual width nor the remote's input-cursor coordinates, so there's no way to compute a correct position automatically. The same pixel offset also looks right on one machine and wrong on another with a different resolution/OS scale factor. Fixed by making the offset drag-adjustable instead (`utils/imeOffset.ts`, persisted to local `localStorage`): once the composition echo box appears while typing, just drag it to line up with the real candidate window and let go — a new machine needs a one-time re-drag.
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
