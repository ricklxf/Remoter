@echo off
chcp 65001 > nul
setlocal EnableExtensions EnableDelayedExpansion

REM Remoter-Win Startup Script
REM Start program and keep running, kill process when closed

echo ===== Remoter-Win Startup Script =====
echo.

REM Check admin rights
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [OK] Running as administrator
) else (
    echo [WARN] Not running as administrator
    echo        Recommend: Run as admin for full functionality
    echo.
)

REM Kill old processes
echo [1/4] Check and kill old processes...
taskkill /F /IM RemoterWin.exe >nul 2>&1
if %errorLevel% == 0 (
    echo        Killed old process
    timeout /t 1 >nul
) else (
    echo        No old process found
)
echo.

REM Check executable
echo [2/4] Check program file...
set "exePath=%~dp0bin\Release\net8.0-windows\RemoterWin.exe"
if not exist "%exePath%" (
    echo        ERROR: Executable not found
    echo        Path: %exePath%
    echo.
    echo        Please run build.bat first
    pause
    exit /b 1
)
echo        Found: %exePath%
echo.

REM Start program
REM Plain `start` doesn't reliably detach when this script itself is running
REM inside Windows Terminal/VS Code's integrated terminal: those host the
REM whole console in a Job Object, and Windows silently adds `start`-launched
REM children to that same job unless the job explicitly allows breakaway
REM (most don't) — so closing that terminal tab kills RemoterWin.exe right
REM along with it, even though it looks fully detached. PowerShell's
REM Start-Process requests CREATE_BREAKAWAY_FROM_JOB, which actually escapes it.
echo [3/4] Starting program...
powershell -NoProfile -Command "Start-Process -FilePath '%exePath%'"
timeout /t 2 >nul

REM Check if program started successfully
tasklist /FI "IMAGENAME eq RemoterWin.exe" 2>nul | find /I "RemoterWin.exe" >nul
if %errorLevel% == 0 (
    echo        OK: Program started successfully
    for /f "tokens=2" %%i in ('tasklist /FI "IMAGENAME eq RemoterWin.exe" /NH ^| find "RemoterWin.exe"') do (
        set "PID=%%i"
    )
    echo        PID: !PID!
) else (
    echo        ERROR: Program failed to start
    pause
    exit /b 1
)
echo.

REM Keep running and monitor
echo [4/4] Monitoring program...
echo        ========================================
echo        Program is running
echo        Press Ctrl+C to stop the program
echo        ========================================
echo.

:MONITOR_LOOP
timeout /t 1 >nul
tasklist /FI "IMAGENAME eq RemoterWin.exe" 2>nul | find /I "RemoterWin.exe" >nul
if %errorLevel% == 0 (
    goto MONITOR_LOOP
)

REM Program exited, cleanup
:CLEANUP
echo.
echo        ========================================
echo        Program exited, cleaning up...
echo        ========================================
echo.

taskkill /F /IM RemoterWin.exe >nul 2>&1
if %errorLevel% == 0 (
    echo        Cleaned up residual processes
) else (
    echo        No residual processes
)

echo.
echo ===== Program stopped =====
echo.
pause
