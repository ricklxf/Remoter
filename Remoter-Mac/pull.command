#!/usr/bin/env bash
# 双击运行：拉取最新代码（在 Finder 里双击即可，不用开终端）
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "===== Pull Remoter-Mac ====="
echo ""
git pull
echo ""
echo "===== Pull Complete ====="
echo "提示：接下来双击 build.command 重新构建"
echo ""
read -p "按 Enter 关闭窗口..."
