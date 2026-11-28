#!/usr/bin/env bash
# 双击运行：拉取最新代码 + 编译打包安装到 /Applications + 重启，一步到位
set -e
# 任何一步失败都停住窗口显示报错，否则 set -e 退出后终端窗口会直接关掉
trap 'echo ""; echo "!!! 更新失败（见上方报错）"; read -p "按 Enter 关闭窗口..."' ERR
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Update Remoter-MacClient (pull + build) ====="
echo ""
echo "[1/2] Pulling latest changes..."
git pull
echo ""

echo "[2/2] Building..."
echo ""
bash scripts/build-app.sh --release --install
echo ""

echo "[重启] 关闭正在运行的旧实例（如果有）..."
pkill -x RemoterClient 2>/dev/null || true
sleep 1
open /Applications/RemoterClient.app
echo "       OK: 已启动新版本"
echo ""

echo "===== Update Complete ====="
echo ""
read -p "按 Enter 关闭窗口..."
