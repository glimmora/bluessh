#!/usr/bin/env bash
# Cross-compile BlueSSH engine for Windows from Linux using cargo-xwin.
# Flutter UI build for Windows requires a Windows host, so only the
# Rust engine (bluessh.dll) is cross-compiled here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"
UI_DIR="$PROJECT_ROOT/ui"
DIST_DIR="$PROJECT_ROOT/dist"

BUILD_MODE="release"

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug) BUILD_MODE="debug"; shift ;;
        *) echo "Usage: $0 [--debug]"; exit 1 ;;
    esac
done

# Ensure cross-compile tools are on PATH
export PATH="/home/blue/.local/bin:/tmp/nasm_extracted/usr/bin:$PATH"

echo "═══════════════════════════════════════════════════════════"
echo "  BlueSSH Windows Cross-Build (Engine Only)"
echo "  Project: $PROJECT_ROOT"
echo "  Mode:    $BUILD_MODE"
echo "═══════════════════════════════════════════════════════════"

# ─── Step 1: Build Rust Engine for Windows ──────────────────────
echo ""
echo "━━━ Step 1: Building Rust engine for Windows ━━━"
cd "$ENGINE_DIR"

if [[ "$BUILD_MODE" == "release" ]]; then
    cargo xwin build --release --target x86_64-pc-windows-msvc 2>&1
else
    cargo xwin build --target x86_64-pc-windows-msvc 2>&1
fi

# Verify DLL was built
DLL_PATH="$ENGINE_DIR/target/x86_64-pc-windows-msvc/${BUILD_MODE}/bluessh.dll"
if [[ ! -f "$DLL_PATH" ]]; then
    echo "ERROR: DLL not found at $DLL_PATH"
    exit 1
fi
SIZE=$(du -h "$DLL_PATH" | cut -f1)
echo "  Built: $DLL_PATH ($SIZE)"

# ─── Step 2: Place DLL ─────────────────────────────────────────
echo ""
echo "━━━ Step 2: Placing library ━━━"
WIN_RUNNER_DIR="$UI_DIR/windows/runner"
mkdir -p "$WIN_RUNNER_DIR"
cp "$DLL_PATH" "$WIN_RUNNER_DIR/"
echo "  Copied bluessh.dll to $WIN_RUNNER_DIR/"

# ─── Step 3: Flutter UI (requires Windows host) ────────────────
echo ""
echo "━━━ Step 3: Flutter UI build ━━━"
echo "  SKIPPED: Flutter 'build windows' requires a Windows host."
echo "  The engine DLL has been cross-compiled and placed."
echo "  Run 'flutter build windows' on a Windows machine to complete."

# ─── Summary ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Build Complete!"
echo ""
echo "  Engine: $DLL_PATH"
echo "  DLL placed: $WIN_RUNNER_DIR/bluessh.dll"
echo ""
echo "  Note: Flutter Windows UI build requires a Windows host."
echo "  The original build_windows.bat should be run on Windows"
echo "  to complete Steps 3-4 (Flutter build + packaging)."
echo "═══════════════════════════════════════════════════════════"
