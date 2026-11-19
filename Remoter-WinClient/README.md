# Remoter-WinClient

Pure native Windows remote desktop client for **Remoter**, built with **C# .NET 10 (`net10.0-windows`)**, **Direct3D 11 + DXGI 1.2 Flip-Model**, **Media Foundation Hardware Video/Audio Decoding**, **WASAPI**, and **Win32 RawInput**.

## Architecture

- **Zero Browser / Zero Electron Overhead**: Direct Win32 `HWND` hosting a DXGI 1.2 `FlipDiscard` SwapChain (`MaximumFrameLatency = 1`, `AllowTearing` VRR/low-latency support) with GPU zero-copy NV12 → BGRA HLSL pixel shader rendering.
- **Hardware Video & Audio Decoding**:
  - `Video/MfVideoDecoder.cs`: Media Foundation DXGI-aware hardware H.264 / H.265 (HEVC) decoding (NVIDIA NVDEC / Intel QuickSync / AMD VCN) with automatic software fallback and `Video/JpegDecoder.cs` GDI+ fallback.
  - `Audio/WasapiAudioPlayer.cs`: Native WASAPI low-latency audio playback with Media Foundation AAC-ADTS decoding.
- **Pure Win32 Native Input**:
  - `Input/RawInputManager.cs`: `RegisterRawInputDevices` / `WM_INPUT` high-polling-rate mouse & 3D game relative mouse mode (Pointer Lock via `ClipCursor` + `ShowCursor`, toggled with `Ctrl+Alt+Enter` or toolbar button).
  - Precision touchpad & discrete mouse wheel support with sub-notch pixel delta preservation, soft axis lock, and 120Hz coalescing.
  - `Input/KeyCodeMapper.cs`: Full Windows VK / ScanCode → W3C `KeyboardEvent.code` mapping with Win/Alt interception while focused and automatic key release on focus loss.
  - `Input/ClipboardSync.cs`: Native `AddClipboardFormatListener` (`WM_CLIPBOARDUPDATE`) bidirectional text & PNG image clipboard sync with FNV-1a 64-bit anti-loop hashing.
- **Wire-Compatible Protocol**:
  - `Network/RemoterConnection.cs`: Native `ClientWebSocket` with TLS self-signed cert acceptance (`CN=Remoter`), auth handshake, heartbeat/RTT measurement, LAN subnet detection (`net_hint`), and 100% compatibility with `Remoter-Mac` and `Remoter-Win` agents.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl + Alt + Enter` | Toggle Game Mouse / Pointer Lock |
| `F11` or `Ctrl + Alt + F` | Toggle Fullscreen |

## Build & Run (Windows)

Requires **.NET 10 SDK** (`net10.0-windows`).

- Double-click **`build.bat`** to kill any running instance, restore NuGet packages, build Release, publish a self-contained `win-x64` package to `publish\`, and launch `RemoterWinClient.exe`.
- Double-click **`update.bat`** to `git pull` and run `build.bat` in one step.
