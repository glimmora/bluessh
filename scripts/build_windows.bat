@echo off
REM ══════════════════════════════════════════════════════════════════════
REM  build_windows.bat — BlueSSH Windows Build Script
REM
REM  Builds the Rust engine and Flutter UI for Windows desktop.
REM  Produces:
REM    dist\BlueSSH-windows-x64.zip     — portable ZIP archive
REM
REM  Monitored by watch_windows.ps1 for auto-fix on failure.
REM
REM  Usage:
REM    build_windows.bat [--debug]
REM ══════════════════════════════════════════════════════════════════════
setlocal enabledelayedexpansion

set PROJECT_ROOT=%~dp0..
set DIST_DIR=%PROJECT_ROOT%\dist
set BUILD_MODE=release
set FLUTTER_FLAGS=--release

REM Parse arguments
if "%1"=="--debug" (
    set BUILD_MODE=debug
    set FLUTTER_FLAGS=--debug
)

echo ===========================================================
echo   BlueSSH Windows Build
echo   Project: %PROJECT_ROOT%
echo   Mode:    %BUILD_MODE%
echo ===========================================================

REM ─── Step 1: Build Rust Engine ──────────────────────────────────
echo.
echo --- Step 1: Building Rust engine ---
cd /d "%PROJECT_ROOT%\engine"
if errorlevel 1 (
    echo ERROR: Cannot cd to engine directory
    exit /b 1
)

if "%BUILD_MODE%"=="release" (
    cargo build --release
) else (
    cargo build
)
if errorlevel 1 (
    echo ERROR: Rust build failed
    exit /b 1
)

REM ─── Step 2: Place DLL ─────────────────────────────────────────
echo.
echo --- Step 2: Placing library ---
if not exist "%PROJECT_ROOT%\ui\windows\runner" mkdir "%PROJECT_ROOT%\ui\windows\runner"

if "%BUILD_MODE%"=="release" (
    copy /Y "%PROJECT_ROOT%\engine\target\release\bluessh.dll" "%PROJECT_ROOT%\ui\windows\runner\"
) else (
    copy /Y "%PROJECT_ROOT%\engine\target\debug\bluessh.dll" "%PROJECT_ROOT%\ui\windows\runner\"
)
if errorlevel 1 (
    echo ERROR: Failed to copy DLL
    exit /b 1
)

REM ─── Step 3: Build Flutter UI ──────────────────────────────────
echo.
echo --- Step 3: Building Flutter UI ---
cd /d "%PROJECT_ROOT%\ui"
call flutter pub get
if errorlevel 1 (
    echo ERROR: flutter pub get failed
    exit /b 1
)

call flutter build windows %FLUTTER_FLAGS%
if errorlevel 1 (
    echo ERROR: Flutter build failed
    exit /b 1
)

REM ─── Step 4: Package Artifacts ──────────────────────────────────
echo.
echo --- Step 4: Packaging artifacts ---

if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

set BUNDLE_DIR=%PROJECT_ROOT%\ui\build\windows\x64\runner\Release

if not exist "%BUNDLE_DIR%\bluessh.exe" (
    echo ERROR: Build output not found at %BUNDLE_DIR%
    exit /b 1
)

REM Create portable ZIP using PowerShell
set ZIP_FILE=%DIST_DIR%\BlueSSH-windows-x64-%BUILD_MODE%.zip
echo   Creating ZIP: %ZIP_FILE%
powershell -NoProfile -Command "Compress-Archive -Path '%BUNDLE_DIR%\*' -DestinationPath '%ZIP_FILE%' -Force"
if errorlevel 1 (
    echo   WARNING: PowerShell Compress-Archive failed
    echo   Trying tar fallback...
    cd /d "%BUNDLE_DIR%"
    tar -a -c -f "%ZIP_FILE%" *
    cd /d "%PROJECT_ROOT%"
)

for %%A in ("%ZIP_FILE%") do echo   %%~nxA (%%~zA bytes)

REM Copy individual binaries for direct access
copy /Y "%BUNDLE_DIR%\bluessh.exe" "%DIST_DIR%\bluessh.exe" >nul 2>&1

echo.
echo ===========================================================
echo   Build Complete!
echo.
echo   Engine: %PROJECT_ROOT%\engine\target\%BUILD_MODE%\bluessh.dll
echo   Bundle: %BUNDLE_DIR%
echo.
echo   Distribution artifacts:
dir /B "%DIST_DIR%\BlueSSH-windows-*" 2>nul
echo ===========================================================

exit /b 0
