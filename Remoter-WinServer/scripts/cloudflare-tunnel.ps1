# cloudflare-tunnel.ps1 — 通过 Cloudflare Quick Tunnel 把 Remoter 暴露到公网
#
# 无需 Cloudflare 账号，每次启动随机生成一个 trycloudflare.com 域名（含 TLS）。
# 控制端填写打印出的 wss:// 地址即可跨网络连接。
#
# 用法：
#   .\scripts\cloudflare-tunnel.ps1             # 默认端口 7788
#   .\scripts\cloudflare-tunnel.ps1 -Port 7789  # 自定义端口
#
# 安装 cloudflared：
#   https://github.com/cloudflare/cloudflared/releases/latest
#   下载 cloudflared-windows-amd64.exe，改名为 cloudflared.exe 放到 PATH 里

param([int]$Port = 7788)

if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    Write-Host "❌ 未找到 cloudflared" -ForegroundColor Red
    Write-Host ""
    Write-Host "下载地址：" -ForegroundColor Yellow
    Write-Host "  https://github.com/cloudflare/cloudflared/releases/latest"
    Write-Host ""
    Write-Host "下载 cloudflared-windows-amd64.exe，改名为 cloudflared.exe，"
    Write-Host "放到 C:\Windows\System32 或其他 PATH 目录中。"
    exit 1
}

Write-Host "▶ Cloudflare Tunnel → ws://localhost:$Port" -ForegroundColor Cyan
Write-Host ""
Write-Host "  隧道建立后下方会打印 trycloudflare.com 地址，" -ForegroundColor Gray
Write-Host "  把 https:// 改为 wss:// 填入控制端「直连地址」即可。" -ForegroundColor Gray
Write-Host ""
Write-Host "  示例：wss://xxx-xxx-xxx.trycloudflare.com" -ForegroundColor Green
Write-Host ""
Write-Host "  按 Ctrl+C 停止隧道" -ForegroundColor Gray
Write-Host "─────────────────────────────────────────────" -ForegroundColor DarkGray

& cloudflared tunnel --url "ws://localhost:$Port"
