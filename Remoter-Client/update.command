#!/usr/bin/env bash
# 双击运行：拉取最新代码 + 打包 + 重启，一步到位
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Update Remoter-Client (pull + build) ====="
echo ""
echo "[1/2] Pulling latest changes..."
git pull
echo ""

echo "[2/2] Building..."
echo ""
bash build.command
