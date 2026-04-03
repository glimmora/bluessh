@echo off
REM BlueSSH Desktop Build Script for Windows
REM Builds the C++ Qt6 application using Visual Studio

echo === BlueSSH Desktop Build Script for Windows ===

REM Check for Visual Studio
where cl.exe >nul 2>nul
if %errorlevel% neq 0 (
    echo Error: Visual Studio C++ compiler not found
    echo Please run this from "Developer Command Prompt for VS"
    exit /b 1
)

REM Check for Qt
where qmake.exe >nul 2>nul
if %errorlevel% neq 0 (
    echo Error: Qt not found
    echo Please add Qt bin directory to PATH
    exit /b 1
)

REM Create build directory
if exist build (
    echo Cleaning build directory...
    rmdir /s /q build
)

mkdir build
cd build

REM Configure with CMake
echo Configuring build...
cmake .. ^
    -G "Visual Studio 17 2022" ^
    -A x64 ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_INSTALL_PREFIX="C:\Program Files\BlueSSH"

REM Build
echo Building...
cmake --build . --config Release

REM Install (optional)
if "%1"=="--install" (
    echo Installing...
    cmake --install . --config Release
    echo BlueSSH installed to C:\Program Files\BlueSSH
)

echo === Build Complete ===
echo Binary: build\Release\bluessh.exe
echo Run with: build\Release\bluessh.exe

cd ..
pause
