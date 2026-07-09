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
rem rcedit occasionally fails with "Unable to commit changes" because AV
rem real-time scanning locks the freshly-written exe right when rcedit tries
rem to write version info into it. electron-builder's own internal retries
rem happen almost instantly and don't give the lock time to clear, so retry
rem here with an actual multi-second pause between attempts.
set "buildAttempt=0"
:packageRetry
set /a buildAttempt+=1
call npm run package:win
if not errorlevel 1 goto packageOk
if %buildAttempt% GEQ 3 (
    echo       ERROR: Build failed after 3 attempts
    echo       If this keeps happening, add an antivirus exclusion for this
    echo       folder and for %%LOCALAPPDATA%%\electron-builder\Cache
    pause
    exit /b 1
)
echo       Build attempt %buildAttempt% failed, waiting for AV scan to clear then retrying...
timeout /t 8 > nul
goto packageRetry
:packageOk
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
