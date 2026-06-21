@echo off
chcp 65001 > nul

REM Pull latest code from GitHub
REM Usage: double-click to update this checkout before running build.bat

echo ===== Pull Remoter-Win =====
echo.

cd /d "%~dp0"

echo [1/1] Pulling latest changes...
git pull
if errorlevel 1 (
    echo       ERROR: git pull failed
    pause
    exit /b 1
)
echo       OK: Pull complete
echo.

echo ===== Pull Complete =====
echo.
echo Hint: Run build.bat next to rebuild.
echo.
pause
