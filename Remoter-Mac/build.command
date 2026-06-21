#!/usr/bin/env bash
# 双击运行：编译并打包 RemoterAgent.app，自动重启正在跑的旧实例
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Build Remoter-Mac ====="
echo ""
bash scripts/build-app.sh
echo ""

echo "[重启] 关闭正在运行的旧实例（如果有）..."
pkill RemoterAgent 2>/dev/null || true
sleep 1
open build/RemoterAgent.app
echo "       OK: 已启动新版本"
echo ""

echo "===== Build Complete ====="
echo ""
read -p "按 Enter 关闭窗口..."
