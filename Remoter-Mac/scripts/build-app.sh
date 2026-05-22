#!/usr/bin/env bash
# build-app.sh — 编译 RemoterAgent 并打包为可运行的 .app bundle
#
# 用法：
#   ./scripts/build-app.sh                  # Debug build → build/RemoterAgent.app
#   ./scripts/build-app.sh --release        # Release build（更小更快）
#   ./scripts/build-app.sh --install        # 同时安装到 /Applications
#
# 运行：
#   open build/RemoterAgent.app             # 自动生成随机 PIN
#   open build/RemoterAgent.app --args --pin 123456   # 指定 PIN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # Remoter-Mac/
OUT_DIR="$PKG_DIR/build"
APP_DIR="$OUT_DIR/RemoterAgent.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FW_DIR="$APP_DIR/Contents/Frameworks"

# ── 解析参数 ──────────────────────────────────────────────────────────────
CONFIG="debug"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --install) INSTALL=1 ;;
    esac
done

echo "▶ Building RemoterAgent ($CONFIG)…"

# ── 编译 ──────────────────────────────────────────────────────────────────
swift build \
    --package-path "$PKG_DIR" \
    $([ "$CONFIG" = "release" ] && echo "-c release" || true)

BUILD_DIR="$PKG_DIR/.build/$CONFIG"

# ── 清理旧 bundle ─────────────────────────────────────────────────────────
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FW_DIR"

# ── 拷贝可执行文件 ────────────────────────────────────────────────────────
cp "$BUILD_DIR/RemoterAgent" "$MACOS_DIR/RemoterAgent"

# ── 拷贝 WebRTC.framework ─────────────────────────────────────────────────
# @rpath 解析路径：@loader_path，即 binary 同目录
cp -R "$BUILD_DIR/WebRTC.framework" "$MACOS_DIR/WebRTC.framework"

# ── 写 Info.plist ─────────────────────────────────────────────────────────
# LSUIElement = YES → 纯菜单栏 app，不在 Dock 显示，不在 App Switcher 显示
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>RemoterAgent</string>
    <key>CFBundleIdentifier</key>
    <string>com.remoter.agent</string>
    <key>CFBundleName</key>
    <string>RemoterAgent</string>
    <key>CFBundleDisplayName</key>
    <string>Remoter Agent</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 屏幕录制权限说明（用于 ScreenCaptureKit）-->
    <key>NSScreenCaptureUsageDescription</key>
    <string>Remoter 需要屏幕录制权限才能捕获画面并传输给远程客户端。</string>
    <!-- 辅助功能权限说明（用于 CGEvent 注入鼠标/键盘）-->
    <key>NSAppleEventsUsageDescription</key>
    <string>Remoter 需要辅助功能权限才能将远程操作注入到本机。</string>
</dict>
</plist>
PLIST

echo "✅ Built: $APP_DIR"
echo ""

# ── 安装到 /Applications ──────────────────────────────────────────────────
if [ "$INSTALL" -eq 1 ]; then
    echo "▶ Installing to /Applications…"
    rm -rf "/Applications/RemoterAgent.app"
    cp -R "$APP_DIR" "/Applications/RemoterAgent.app"
    echo "✅ Installed: /Applications/RemoterAgent.app"
    echo ""
fi

# ── 使用说明 ──────────────────────────────────────────────────────────────
APP_PATH="$([ "$INSTALL" -eq 1 ] && echo "/Applications/RemoterAgent.app" || echo "$APP_DIR")"

echo "📦 使用方法："
echo "   open \"$APP_PATH\"                       # 随机 PIN 启动"
echo "   open \"$APP_PATH\" --args --pin 123456   # 指定 PIN"
echo ""
echo "⚠️  首次运行需在系统设置中授权："
echo "   隐私与安全 → 屏幕录制 → 允许 Terminal / RemoterAgent"
echo "   隐私与安全 → 辅助功能 → 允许 Terminal / RemoterAgent"
