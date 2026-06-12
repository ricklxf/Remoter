#!/usr/bin/env bash
# build-mac.sh — 一键构建：Web 客户端 + Mac 被控端（含嵌入 web 资源）
#
# 用法：
#   bash scripts/build-mac.sh               # debug 包
#   bash scripts/build-mac.sh --release     # release 包（更小更快）
#   bash scripts/build-mac.sh --install     # release + 安装到 /Applications
#
# 依赖：
#   Node.js 18+（npm）
#   Swift 5.9+（xcode-select --install）

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Step 0: 同步版本号 ────────────────────────────────────────────────────
VERSION=$(node -p "require('$ROOT/Remoter-Client/package.json').version")
echo "let kAppVersion = \"$VERSION\"" > "$ROOT/Remoter-Mac/Sources/RemoterAgent/AppVersion.swift"
echo "  ✓ AppVersion.swift → $VERSION"

# ── Step 1: Web 客户端 ─────────────────────────────────────────────────────
echo "▶ [1/2] Building web client…"
cd "$ROOT/Remoter-Client"
if [ ! -d node_modules ]; then
    echo "  npm install…"
    npm install --silent
fi
npm run build:web
echo "  ✓ Web client → Remoter-Server/public/"

# ── Step 2: Mac app（build-app.sh 会自动嵌入 Remoter-Server/public/）────────
echo ""
echo "▶ [2/2] Building Mac app…"
cd "$ROOT/Remoter-Mac"
bash scripts/build-app.sh "$@"

echo ""
echo "✅ All done."
echo "   App  : Remoter-Mac/build/RemoterAgent.app"
echo "   Web  : embedded → http://<LAN-IP>:7788"
