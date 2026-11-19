@echo off
chcp 65001 > nul
::build_start
REM Remoter-WinClient Build Script
REM Usage: Compile pure native Windows client (C# .NET 10 + D3D11 + Media Foundation + RawInput)
echo ===== Remoter-WinClient Build Script =====
echo.

cd /d "%~dp0"

REM Kill running process before build
echo [1/5] Stopping running process...
taskkill /F /IM RemoterWinClient.exe > nul 2>&1
if errorlevel 1 (
    echo       OK: No running process found
) else (
    echo       OK: Old process killed
    timeout /t 2 > nul
)
echo.

REM Check .NET SDK
echo [2/5] Checking .NET SDK...
dotnet --version > nul 2>&1
if errorlevel 1 (
    echo       ERROR: .NET SDK not found, please install .NET 10 SDK
    echo       Download: https://dotnet.microsoft.com/download/dotnet/10.0
    pause
    exit /b 1
)
for /f "tokens=*" %%i in ('dotnet --version') do set DOTNET_VERSION=%%i
echo       OK: .NET SDK %DOTNET_VERSION% found
echo.

REM Restore NuGet packages
echo [3/5] Restoring NuGet packages...
dotnet restore
if errorlevel 1 (
    echo       ERROR: NuGet restore failed
    pause
    exit /b 1
)
echo       OK: NuGet packages restored
echo.

REM Build project (Release)
echo [4/5] Building project (Release)...
dotnet build -c Release
if errorlevel 1 (
    echo       ERROR: Build failed
    pause
    exit /b 1
)
echo       OK: Build successful
echo.

REM Publish self-contained version (for distribution)
echo [5/5] Publishing self-contained version...
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o publish
if errorlevel 1 (
    echo       WARN: Publish failed, but build succeeded
) else (
    echo       OK: Self-contained version published to publish\ directory
    echo           You can distribute the publish\ directory without .NET Runtime
)
echo.

set "outputDir=%~dp0bin\Release\net10.0-windows"
set "exePath=%outputDir%\RemoterWinClient.exe"

echo Starting new build...
if exist "%exePath%" (
    start "" "%exePath%"
    timeout /t 2 > nul
    tasklist /FI "IMAGENAME eq RemoterWinClient.exe" 2>nul | find /I "RemoterWinClient.exe" > nul
    if %errorLevel% == 0 (
        echo       OK: Program started successfully
    ) else (
        echo       WARN: Build succeeded but process did not stay running
    )
) else (
    echo       WARN: Executable not found at %exePath%, skipping auto-start
)
echo.

echo ===== Build successful! =====
echo.
echo Output path: %outputDir%
echo Executable: RemoterWinClient.exe
echo.
echo Self-contained package: %~dp0publish\
echo   (Can run without .NET Runtime installed)
echo.
pause
