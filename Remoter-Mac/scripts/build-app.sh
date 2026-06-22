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
ROOT_DIR="$(cd "$PKG_DIR/.." && pwd)"
OUT_DIR="$PKG_DIR/build"
APP_DIR="$OUT_DIR/RemoterAgent.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FW_DIR="$APP_DIR/Contents/Frameworks"

# ── 同步版本号 ──────────────────────────────────────────────────────────
# AppVersion.swift 是构建产物（不进 git，见 .gitignore）：每台机器各自构建
# 都会改写它，提交进版本库只会导致两边版本号在 git pull 时打架冲突。
VERSION=$(node -p "require('$ROOT_DIR/Remoter-Client/package.json').version")
echo "let kAppVersion = \"$VERSION\"" > "$PKG_DIR/Sources/RemoterAgent/AppVersion.swift"
echo "  ✓ AppVersion.swift → $VERSION"

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

# ── 嵌入 Web 客户端（可选）────────────────────────────────────────────────
# 优先读 Remoter-Server/public（build:web 的默认输出），兼容旧路径 dist-web
WEB_DIST=""
if [ -d "$PKG_DIR/../Remoter-Server/public" ]; then
    WEB_DIST="$PKG_DIR/../Remoter-Server/public"
elif [ -d "$PKG_DIR/../Remoter-Client/dist-web" ]; then
    WEB_DIST="$PKG_DIR/../Remoter-Client/dist-web"
fi
RESOURCES_DIR="$APP_DIR/Contents/Resources"
if [ -n "$WEB_DIST" ]; then
    echo ""
    echo "▶ 嵌入 Web 客户端…"
    mkdir -p "$RESOURCES_DIR"
    rm -rf "$RESOURCES_DIR/web"
    cp -R "$WEB_DIST" "$RESOURCES_DIR/web"
    echo "✅ Web 客户端已嵌入（浏览器访问 https://<ip>:7788）"
fi

# ── 生成/嵌入 TLS 自签证书（HTTPS/WSS）──────────────────────────────────
# WebCodecs(H.264 解码) 需要安全上下文(HTTPS)；自签证书首次访问需手动信任。
# 证书持久保存在 Remoter-Mac/certs/，存在则复用 → 只需信任一次。
CERT_DIR="$PKG_DIR/certs"

if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
    echo ""
    echo "▶ 生成自签 TLS 证书…"
    mkdir -p "$CERT_DIR"
    # 收集本机所有局域网 IP + mDNS .local 主机名，拼成 SAN
    # .local 主机名固定不随 IP 变化，是 web 客户端访问的推荐地址
    LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null).local"
    LAN_IPS=$(ifconfig | awk '/inet / && !/127\.0\.0\.1/{print $2}' | tr '\n' ',' | sed 's/,$//')
    SAN="DNS:localhost,DNS:${LOCAL_HOST},IP:127.0.0.1"
    [ -n "$LAN_IPS" ] && SAN="$SAN,$(echo "$LAN_IPS" | sed 's/[^,]*/IP:&/g')"
    echo "  SAN: $SAN"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -subj "/CN=Remoter" \
        -addext "subjectAltName=$SAN" 2>/dev/null
    echo "  ✓ 证书生成 → $CERT_DIR/cert.pem"
fi

# 直接嵌入 PEM 文件：NIOSSL（BoringSSL）从内存加载，完全不碰 macOS keychain，
# 彻底消除 keychain 授权弹框。
mkdir -p "$RESOURCES_DIR"
cp "$CERT_DIR/cert.pem" "$RESOURCES_DIR/server.crt"
cp "$CERT_DIR/key.pem"  "$RESOURCES_DIR/server.key"
echo "✅ TLS 证书已嵌入（PEM 格式，BoringSSL 直接加载）"
echo ""

# ── 代码签名 ─────────────────────────────────────────────────────────────
# designated requirement 只包含 bundle ID，不绑定证书 hash。
# 这样 TCC 的辅助功能授权在每次 rebuild 后仍然有效（只需授权一次）。
DR='=designated => identifier "com.remoter.agent"'
# 只找代码签名身份（code signing），避免把 TLS 证书误认为签名证书
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Remoter"'; then
    echo "▶ Signing with \"Remoter\" identity…"
    codesign --force --deep --sign "Remoter" --requirements "$DR" "$APP_DIR"
    echo "✅ Signed (designated req: bundle ID only)"
else
    echo "▶ Signing ad-hoc (designated req: bundle ID only)…"
    codesign --force --deep --sign - --requirements "$DR" "$APP_DIR"
    echo "✅ Signed ad-hoc"
fi
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
