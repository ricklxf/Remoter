@echo off
chcp 65001 > nul

REM Restart Script
REM Kill old process and start new one

echo ===== Restart Remoter-Win =====
echo.

REM Kill old process
echo [1/2] Killing old process...
taskkill /F /IM RemoterWin.exe >nul 2>&1
if %errorLevel% == 0 (
    echo        OK: Killed old process
    timeout /t 2 >nul
) else (
    echo        No old process found
)
echo.

REM Start new process
echo [2/2] Starting new process...
set "exePath=%~dp0bin\Release\net8.0-windows\RemoterWin.exe"
if not exist "%exePath%" (
    echo        ERROR: Executable not found
    echo        Path: %exePath%
    echo.
    echo        Please run build.bat first
    pause
    exit /b 1
)

REM PowerShell's Start-Process (not plain `start`) — see run.bat for why:
REM `start` doesn't reliably escape the parent terminal's Job Object when run
REM from Windows Terminal/VS Code, so closing that window kills this process
REM too even though it looks detached.
powershell -NoProfile -Command "Start-Process -FilePath '%exePath%'"
timeout /t 3 >nul

REM Check if started successfully
tasklist /FI "IMAGENAME eq RemoterWin.exe" 2>nul | find /I "RemoterWin.exe" >nul
if %errorLevel% == 0 (
    echo        OK: Program started successfully
    echo.
    echo        Admin interface: http://localhost:7790
    echo        Web interface: http://localhost:7788
) else (
    echo        ERROR: Program failed to start
)
echo.

echo ===== Restart Complete =====
echo.
pause
