# build-win.ps1 — 一键构建：Web 客户端 + Win 被控端（含嵌入 web 资源）
#
# 用法（在项目根目录运行）：
#   powershell -ExecutionPolicy Bypass -File scripts\build-win.ps1
#
# 依赖：
#   Node.js 18+（npm）
#   .NET 8 SDK（dotnet）

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot   # scripts/ 的父目录，即项目根

# ── Step 1: Web 客户端 ─────────────────────────────────────────────────────
Write-Host "▶ [1/3] Building web client…" -ForegroundColor Cyan
Set-Location "$root\Remoter-Client"
if (-not (Test-Path node_modules)) {
    Write-Host "  npm install…" -ForegroundColor Gray
    npm install --silent
}
npm run build:web
Write-Host "  ✓ Web client → Remoter-Server\public\" -ForegroundColor Green

# ── Step 2: Win agent ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "▶ [2/3] Building Win agent…" -ForegroundColor Cyan
Set-Location "$root\Remoter-Win"
dotnet publish -r win-x64 -c Release -p:PublishSingleFile=true --self-contained
$publishDir = "$root\Remoter-Win\bin\Release\net8.0-windows\win-x64\publish"
Write-Host "  ✓ Exe → $publishDir\RemoterWin.exe" -ForegroundColor Green

# ── Step 3: 嵌入 web 资源 ─────────────────────────────────────────────────
Write-Host ""
Write-Host "▶ [3/3] Embedding web client into publish dir…" -ForegroundColor Cyan
$webSrc = "$root\Remoter-Server\public"
$webDst = "$publishDir\web"
if (Test-Path $webDst) { Remove-Item $webDst -Recurse -Force }
Copy-Item $webSrc $webDst -Recurse
Write-Host "  ✓ Web → $webDst\" -ForegroundColor Green

Write-Host ""
Write-Host "✅ All done." -ForegroundColor Green
Write-Host "   Exe  : $publishDir\RemoterWin.exe"
Write-Host "   Web  : embedded → http://<LAN-IP>:7799"
