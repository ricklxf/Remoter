# Downloads FFmpeg 7.1 shared DLLs (avcodec-61.dll, avutil-59.dll, swresample-5.dll)
# for Remoter-WinClient D3D11VA zero-copy H.264 / H.265 (HEVC) hardware decoding.
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path (Split-Path -Parent $scriptDir) "libs\ffmpeg"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$zipUrl = "https://github.com/GyanD/codexffmpeg/releases/download/7.1.1/ffmpeg-7.1.1-full_build-shared.zip"
$tmpZip = Join-Path $env:TEMP "remoter-ffmpeg-7.1.1-shared.zip"
$tmpExtract = Join-Path $env:TEMP "remoter-ffmpeg-7.1.1-extract"

Write-Host "Downloading FFmpeg 7.1.1 shared (GyanD codexffmpeg win64)..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing

if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
Write-Host "Extracting DLLs..."
Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force

$required = @("avcodec-61.dll", "avutil-59.dll", "swresample-5.dll")
$binDirs = Get-ChildItem -Path $tmpExtract -Directory -Recurse | Where-Object { $_.Name -eq "bin" }
$copied = 0
foreach ($bin in $binDirs) {
    foreach ($dll in $required) {
        $src = Join-Path $bin.FullName $dll
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $outDir $dll) -Force
            $copied++
        }
    }
}

Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue

if ($copied -lt 2) {
    throw "Failed to extract FFmpeg 7.1 DLLs (copied=$copied). Check archive structure."
}

Write-Host "Done! FFmpeg 7.1 DLLs installed to: $outDir"
Get-ChildItem $outDir | Select-Object Name, Length
