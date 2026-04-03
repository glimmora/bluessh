#!/bin/bash
# BlueSSH Desktop Build Script for Linux
# Builds the C++ Qt6 application

set -e

echo "=== BlueSSH Desktop Build Script ==="

# Check dependencies
check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "Error: $1 is not installed"
        echo "Please install: $2"
        exit 1
    fi
}

echo "Checking dependencies..."
check_dependency cmake "cmake"
check_dependency g++ "build-essential"
check_dependency pkg-config "pkg-config"
check_dependency qmake6 "qt6-base-dev"

# Check for required libraries
echo "Checking libraries..."
pkg-config --exists libssh2 || { echo "Error: libssh2 not found"; exit 1; }
pkg-config --exists vterm || { echo "Error: libvterm not found"; exit 1; }
pkg-config --exists openssl || { echo "Error: openssl not found"; exit 1; }
pkg-config --exists zlib || { echo "Error: zlib not found"; exit 1; }
pkg-config --exists libzstd || { echo "Error: libzstd not found"; exit 1; }

# Create build directory
BUILD_DIR="build"
if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure
echo "Configuring build..."
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DENABLE_TESTS=ON

# Build
echo "Building..."
make -j$(nproc)

# Install (optional)
if [ "$1" == "--install" ]; then
    echo "Installing..."
    sudo make install
    echo "BlueSSH installed to /usr/local/bin/bluessh"
fi

echo "=== Build Complete ==="
echo "Binary: $BUILD_DIR/bluessh"
echo "Run with: ./$BUILD_DIR/bluessh"
