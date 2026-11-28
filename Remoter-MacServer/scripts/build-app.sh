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

# 非交互 SSH 的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，找不到 Homebrew 的 npm/node，
# 脚本会在构建 Web 客户端时中途退出、根本走不到签名（mac2 远程构建踩过）。
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # Remoter-MacServer/
OUT_DIR="$PKG_DIR/build"
APP_DIR="$OUT_DIR/RemoterAgent.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FW_DIR="$APP_DIR/Contents/Frameworks"
# AppVersion.swift is synced at commit time (pre-commit hook, alongside
# package.json) — not rewritten here, so a build between commits doesn't
# touch a tracked file and fight with `git pull`.

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
    <string>Remoter</string>
    <key>CFBundleDisplayName</key>
    <string>Remoter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

# ── 拷贝 App 图标 ─────────────────────────────────────────────────────────
mkdir -p "$APP_DIR/Contents/Resources"
cp "$PKG_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "✅ Built: $APP_DIR"

# ── 嵌入 Web 客户端（可选）────────────────────────────────────────────────
# Remoter-Server/public 是 build:web 的输出，在 .gitignore 里、从不提交——
# 只跑 git pull 拉不到它。这里每次都从源码重新构建一遍，保证嵌入的是当前
# checkout 出来的最新前端代码，不会用到本机某次手动 build 留下的旧产物。
CLIENT_DIR="$PKG_DIR/../Remoter-Client"
if [ -d "$CLIENT_DIR/node_modules" ]; then
    echo ""
    echo "▶ 构建 Web 客户端…"
    (cd "$CLIENT_DIR" && npm run build:web)
else
    echo "⚠️  $CLIENT_DIR/node_modules 不存在，跳过 Web 客户端构建（先跑一次 npm install）"
fi

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
# 证书持久保存在 Remoter-MacServer/certs/，存在则复用 → 只需信任一次。
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
# 优先使用本地持久化代码签名证书 "Remoter"（让 codesign 生成绑定该证书哈希的
# 标准 designated requirement）：macOS 15+/27 的屏幕/系统音频录制 TCC 会稳定
# 信任同一证书签出的每次 rebuild，彻底告别每次重装弹音频权限框。
# 若无证书或 SSH 会话下钥匙串被锁导致签名失败，自动回退到 ad-hoc 签名。
SIGNED_WITH_CERT=0
if security find-identity -p codesigning 2>/dev/null | grep -q '"Remoter"'; then
    echo "▶ Signing with \"Remoter\" identity…"
    if codesign --force --deep --sign "Remoter" "$APP_DIR" 2>/dev/null; then
        echo "✅ Signed with \"Remoter\" certificate"
        SIGNED_WITH_CERT=1
    else
        echo "⚠️  \"Remoter\" 证书签名失败（可能是 SSH 下登录钥匙串已锁定），回退到 ad-hoc…"
    fi
fi
if [ "$SIGNED_WITH_CERT" -eq 0 ]; then
    DR='designated => identifier "com.remoter.agent"'
    echo "▶ Signing ad-hoc (designated req: bundle ID only)…"
    # -i is required: without it codesign names the signature RemoterAgent-<hash> and the
    # designated requirement falls back to the content cdhash, which changes on every rebuild,
    # so macOS re-asks for Screen Recording / Accessibility after each build (seen on mac2).
    codesign --force --deep --sign - -i com.remoter.agent -r="$DR" "$APP_DIR"
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
