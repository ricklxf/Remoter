#!/usr/bin/env bash
# cloudflare-tunnel.sh — 通过 Cloudflare Quick Tunnel 把 Remoter 暴露到公网
#
# 无需 Cloudflare 账号，每次启动随机生成一个 trycloudflare.com 域名（含 TLS）。
# 控制端填写打印出的 wss:// 地址即可跨网络连接。
#
# 用法：
#   bash scripts/cloudflare-tunnel.sh              # 默认端口 7788
#   bash scripts/cloudflare-tunnel.sh --port 7789  # 自定义端口
#
# 安装 cloudflared：
#   brew install cloudflare/cloudflare/cloudflared

set -euo pipefail

PORT=7788
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if ! command -v cloudflared &>/dev/null; then
    echo "❌ 未找到 cloudflared"
    echo ""
    echo "安装："
    echo "  brew install cloudflare/cloudflare/cloudflared"
    echo ""
    echo "或手动下载："
    echo "  https://github.com/cloudflare/cloudflared/releases/latest"
    exit 1
fi

echo "▶ Cloudflare Tunnel → ws://localhost:$PORT"
echo ""
echo "  隧道建立后下方会打印 trycloudflare.com 地址，"
echo "  把 https:// 改为 wss:// 填入控制端「直连地址」即可。"
echo ""
echo "  示例：wss://xxx-xxx-xxx.trycloudflare.com"
echo ""
echo "  按 Ctrl+C 停止隧道"
echo "─────────────────────────────────────────────"

exec cloudflared tunnel --url "ws://localhost:$PORT"
