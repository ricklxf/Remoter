@echo off
chcp 65001 > nul
::build_start
REM Remoter-Win Build Script
REM Usage: Compile Remoter-Win project with UI
echo ===== Remoter-Win Build Script =====
echo.

REM Kill running process before build
echo [1/6] Stopping running process...
taskkill /F /IM RemoterWin.exe > nul 2>&1
if errorlevel 1 (
    echo       OK: No running process found
) else (
    echo       OK: Old process killed
    timeout /t 2 > nul
)
echo.

REM Check .NET SDK
echo [2/6] Checking .NET SDK...
dotnet --version > nul 2>&1
if errorlevel 1 (
    echo       ERROR: .NET SDK not found, please install .NET 8 SDK
    echo       Download: https://dotnet.microsoft.com/download/dotnet/8.0
    pause
    exit /b 1
)
for /f "tokens=*" %%i in ('dotnet --version') do set DOTNET_VERSION=%%i
echo       OK: .NET SDK %DOTNET_VERSION% found
echo.

REM Restore NuGet packages
echo [3/6] Restoring NuGet packages...
dotnet restore
if errorlevel 1 (
    echo       ERROR: NuGet restore failed
    pause
    exit /b 1
)
echo       OK: NuGet packages restored
echo.

REM Build project (Release)
echo [4/6] Building project (Release)...
dotnet build -c Release
if errorlevel 1 (
    echo       ERROR: Build failed
    pause
    exit /b 1
)
echo       OK: Build successful
echo.

REM Copy web directory to output — pulls from Remoter-Server/public, the
REM single source of truth produced by `npm run build:web` in Remoter-Client.
REM (Used to vendor a stale hand-copied snapshot in Remoter-Win\web — that
REM drifted out of sync with every client-side fix; removed.)
echo [5/6] Copying web directory...
set "outputDir=%~dp0bin\Release\net8.0-windows"
set "webSource=%~dp0..\Remoter-Server\public"
set "webDest=%outputDir%\web"

if not exist "%webSource%" (
    echo       WARN: web build not found at %webSource%
    echo       Run "npm run build:web" in Remoter-Client first
    echo       Skipping web copy
    goto :build_complete
)

if exist "%webDest%" rmdir /S /Q "%webDest%" > nul 2>&1
mkdir "%webDest%" > nul 2>&1
xcopy /E /I /Y "%webSource%" "%webDest%" > nul 2>&1
if errorlevel 1 (
    echo       ERROR: Failed to copy web directory
    pause
    exit /b 1
)
echo       OK: Web directory copied to %webDest%
echo.

REM Publish self-contained version (for distribution)
echo [6/6] Publishing self-contained version...
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o publish
if errorlevel 1 (
    echo       WARN: Publish failed, but build succeeded
) else (
    echo       OK: Self-contained version published to publish\ directory
    echo           You can distribute the publish\ directory without .NET Runtime
)
echo.

::build_complete
REM Show output path
echo ===== Build successful! =====
echo.
echo Output path: %outputDir%
echo Executable: RemoterWin.exe
echo.
echo Self-contained package: %~dp0publish\
echo   (Can run without .NET Runtime installed)
echo.
echo Hint: Run run.bat to start the program with UI
echo.
pause
