#!/usr/bin/env bash
# 双击运行：打包 Mac 版桌面客户端，自动重启正在跑的旧实例
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Build Remoter-Client (mac) ====="
echo ""
npm run package:mac
echo ""

APP="dist/mac-arm64/Remoter.app"
if [ ! -d "$APP" ]; then
  APP=$(find dist -maxdepth 2 -name "Remoter.app" | head -1)
fi

echo "[重启] 关闭正在运行的旧实例（如果有）..."
pkill -f "Remoter.app/Contents/MacOS/Remoter" 2>/dev/null || true
sleep 1
if [ -n "$APP" ] && [ -d "$APP" ]; then
  open "$APP"
  echo "       OK: 已启动 $APP"
else
  echo "       WARN: 没找到打包产物，跳过自动启动"
fi
echo ""

echo "===== Build Complete ====="
echo ""
read -p "按 Enter 关闭窗口..."
