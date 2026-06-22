@echo off
chcp 65001 > nul

REM Pull + Build in one go
REM Usage: double-click to update and rebuild without running two scripts

echo ===== Update Remoter-Win (pull + build) =====
echo.

cd /d "%~dp0"

echo [1/2] Pulling latest changes...
git pull
if errorlevel 1 (
    echo       ERROR: git pull failed
    pause
    exit /b 1
)
echo       OK: Pull complete
echo.

echo [2/2] Building...
echo.
call "%~dp0build.bat"
