@echo off
chcp 65001 > nul

echo ===== Build Remoter-Client (win) =====
echo.

cd /d "%~dp0"

echo [1/3] Stopping running instance...
taskkill /F /IM Remoter.exe > nul 2>&1
if errorlevel 1 (
    echo       OK: No running instance found
) else (
    echo       OK: Old instance killed
    timeout /t 2 > nul
)
echo.

echo [2/3] Packaging (npm run package:win)...
call npm run package:win
if errorlevel 1 (
    echo       ERROR: Build failed
    pause
    exit /b 1
)
echo       OK: Build successful
echo.

echo [3/3] Starting new build...
set "exePath=%~dp0dist\win-unpacked\Remoter.exe"
if exist "%exePath%" (
    start "" "%exePath%"
    timeout /t 2 >nul
    tasklist /FI "IMAGENAME eq Remoter.exe" 2>nul | find /I "Remoter.exe" >nul
    if %errorLevel% == 0 (
        echo       OK: Program started successfully
    ) else (
        echo       WARN: Build succeeded but process did not stay running
    )
) else (
    echo       WARN: Executable not found at %exePath%, skipping auto-start
)
echo.

echo ===== Build Complete =====
echo.
echo Installer: %~dp0dist\Remoter-Setup-*.exe
echo.
pause
