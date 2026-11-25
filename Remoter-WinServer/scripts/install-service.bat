@echo off
setlocal enabledelayedexpansion

set "TASK_NAME=RemoterWinServer"

:: Check Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] This script must be run as Administrator.
    echo Right-click install-service.bat and choose "Run as administrator".
    exit /b 1
)

:: Handle --uninstall / /uninstall
if /i "%~1"=="--uninstall" goto :uninstall
if /i "%~1"=="/uninstall" goto :uninstall

:: Locate RemoterWin.exe relative to scripts\ directory
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "EXE_PATH="

if exist "%ROOT_DIR%\RemoterWin.exe" (
    for %%I in ("%ROOT_DIR%\RemoterWin.exe") do set "EXE_PATH=%%~fI"
) else if exist "%ROOT_DIR%\bin\Release\net8.0-windows\win-x64\publish\RemoterWin.exe" (
    for %%I in ("%ROOT_DIR%\bin\Release\net8.0-windows\win-x64\publish\RemoterWin.exe") do set "EXE_PATH=%%~fI"
) else if exist "%ROOT_DIR%\bin\Release\net8.0-windows\RemoterWin.exe" (
    for %%I in ("%ROOT_DIR%\bin\Release\net8.0-windows\RemoterWin.exe") do set "EXE_PATH=%%~fI"
)

if "%EXE_PATH%"=="" (
    echo [ERROR] RemoterWin.exe not found under "%ROOT_DIR%".
    echo Build or publish Remoter-WinServer first, or pass the full path as an argument:
    echo   install-service.bat "C:\Path\To\RemoterWin.exe"
    if not "%~1"=="" (
        if exist "%~1" (
            for %%I in ("%~1") do set "EXE_PATH=%%~fI"
        )
    )
)

if "%EXE_PATH%"=="" exit /b 1

echo [INFO] Installing scheduled startup task "%TASK_NAME%" for SYSTEM...
echo [INFO] Target executable: "%EXE_PATH%"

schtasks /Create /TN "%TASK_NAME%" /TR "\"%EXE_PATH%\"" /SC ONSTART /RU SYSTEM /RL HIGHEST /F
if %errorlevel% neq 0 (
    echo [ERROR] Failed to register scheduled task "%TASK_NAME%".
    exit /b %errorlevel%
)

echo [OK] Scheduled task "%TASK_NAME%" installed successfully.
echo [INFO] RemoterWinServer will start automatically at boot under SYSTEM (lock screen / UAC ready).
echo [INFO] To start immediately: schtasks /Run /TN "%TASK_NAME%"
echo [INFO] To remove: install-service.bat --uninstall
exit /b 0

:uninstall
echo [INFO] Removing scheduled task "%TASK_NAME%"...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARN] Scheduled task "%TASK_NAME%" was not found or could not be deleted.
    exit /b 0
)
echo [OK] Scheduled task "%TASK_NAME%" removed successfully.
exit /b 0
