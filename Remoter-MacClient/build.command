#!/usr/bin/env bash
# 双击运行：编译并打包 RemoterClient.app，安装到 /Applications 并自动重启旧实例
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Build Remoter-MacClient ====="
echo ""
bash scripts/build-app.sh --release --install
echo ""

echo "[重启] 关闭正在运行的旧实例（如果有）..."
pkill -x RemoterClient 2>/dev/null || true
sleep 1
open /Applications/RemoterClient.app
echo "       OK: 已启动新版本"
echo ""

echo "===== Build Complete ====="
echo ""
read -p "按 Enter 关闭窗口..."
