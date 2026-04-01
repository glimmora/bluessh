#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  build_android.sh — Build the Rust engine for Android and package the
#  complete BlueSSH APK via Flutter.
#
#  Generates per-ABI split APKs when Gradle splits are configured:
#    app-armeabi-v7a-release.apk   (32-bit ARM)
#    app-arm64-v8a-release.apk     (64-bit ARM)
#    app-x86-release.apk           (32-bit x86)
#    app-x86_64-release.apk        (64-bit x86)
#    app-release.apk               (universal — all ABIs)
#
#  Usage:
#    ./scripts/build_android.sh [--debug] [--abi armeabi-v7a|arm64-v8a|x86|x86_64|all]
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# Resolve absolute project root (works regardless of CWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"
UI_DIR="$PROJECT_ROOT/ui"
JNILIBS_DIR="$UI_DIR/android/app/src/main/jniLibs"
DIST_DIR="$PROJECT_ROOT/dist"

# ── Rust target triple for each Android ABI ────────────────────────
# Maps Android ABI name → Rust standard target
abi_to_rust_target() {
    case "$1" in
        armeabi-v7a) echo "armv7-linux-androideabi" ;;
        arm64-v8a)   echo "aarch64-linux-android" ;;
        x86)         echo "i686-linux-android" ;;
        x86_64)      echo "x86_64-linux-android" ;;
        *)           echo ""; return 1 ;;
    esac
}

# Find flutter (prefer non-snap installations)
FLUTTER=""
for candidate in \
    /home/blue/flutter-sdk/bin/flutter \
    /home/blue/sdk/flutter/bin/flutter \
    /opt/flutter/bin/flutter \
    "$(command -v flutter 2>/dev/null || true)"; do
    if [[ -n "$candidate" ]] && [[ -x "$candidate" ]]; then
        if file "$candidate" 2>/dev/null | grep -q "symbolic link to.*snap"; then
            continue
        fi
        FLUTTER="$candidate"
        break
    fi
done
if [[ -z "$FLUTTER" ]]; then
    echo "ERROR: flutter not found. Install Flutter or add to PATH."
    exit 1
fi

# Defaults
BUILD_MODE="release"
ABIS=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")
FLUTTER_BUILD_FLAGS="--release"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_MODE="debug"
            FLUTTER_BUILD_FLAGS="--debug"
            shift
            ;;
        --abi)
            case $2 in
                armeabi-v7a) ABIS=("armeabi-v7a") ;;
                arm64-v8a)   ABIS=("arm64-v8a") ;;
                x86)         ABIS=("x86") ;;
                x86_64)      ABIS=("x86_64") ;;
                all)         ABIS=("armeabi-v7a" "arm64-v8a" "x86" "x86_64") ;;
                *)           echo "Unknown ABI: $2"; exit 1 ;;
            esac
            shift 2
            ;;
        *)
            echo "Usage: $0 [--debug] [--abi armeabi-v7a|arm64-v8a|x86|x86_64|all]"
            exit 1
            ;;
    esac
done

echo "═══════════════════════════════════════════════════════════"
echo "  BlueSSH Android Build"
echo "  Project: $PROJECT_ROOT"
echo "  Mode:    $BUILD_MODE"
echo "  ABIs:    ${ABIS[*]}"
echo "  Flutter: $FLUTTER"
echo "═══════════════════════════════════════════════════════════"

# ─── Verify Prerequisites ───────────────────────────────────────────
check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: $1 not found. Please install it."
        exit 1
    fi
}

check_command cargo
check_command rustup

# Check cargo-ndk
if ! cargo ndk --version &>/dev/null 2>&1; then
    echo "Installing cargo-ndk..."
    cargo install cargo-ndk
fi

# Verify NDK
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        NDK_BASE="$ANDROID_HOME/ndk"
        if [[ -d "$NDK_BASE" ]]; then
            export ANDROID_NDK_HOME="$(ls -d "$NDK_BASE"/*/ 2>/dev/null | sort -V | tail -1)"
        fi
    fi
fi

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "WARNING: ANDROID_NDK_HOME not set. Trying cargo-ndk default lookup."
else
    echo "NDK: $ANDROID_NDK_HOME"
fi

# ─── Step 1: Build Rust Engine for each ABI ─────────────────────────
echo ""
echo "━━━ Step 1: Building Rust engine for Android ━━━"
echo ""

# Install all required Rust targets
RUST_TARGETS=()
for ABI in "${ABIS[@]}"; do
    RUST_TARGETS+=("$(abi_to_rust_target "$ABI")")
done
rustup target add "${RUST_TARGETS[@]}"

for ABI in "${ABIS[@]}"; do
    echo ""
    echo "─── Building for $ABI ($(abi_to_rust_target "$ABI")) ───"

    OUTPUT_DIR="$JNILIBS_DIR/$ABI"
    mkdir -p "$OUTPUT_DIR"

    cd "$ENGINE_DIR"

    # cargo-ndk creates <output>/<abi>/ internally
    if [[ "$BUILD_MODE" == "release" ]]; then
        cargo ndk \
            -t "$ABI" \
            -o "$JNILIBS_DIR" \
            build --release
    else
        cargo ndk \
            -t "$ABI" \
            -o "$JNILIBS_DIR" \
            build
    fi

    # Verify the library was built
    LIB_PATH="$OUTPUT_DIR/libbluessh.so"
    if [[ -f "$LIB_PATH" ]]; then
        SIZE=$(du -h "$LIB_PATH" | cut -f1)
        echo "  Built: $LIB_PATH ($SIZE)"
    else
        echo "  ERROR: Expected library not found at $LIB_PATH"
        echo "  Contents of $OUTPUT_DIR:"
        ls -la "$OUTPUT_DIR" || echo "  (directory empty or missing)"
        exit 1
    fi
done

# ─── Step 2: Build Flutter APK ──────────────────────────────────────
echo ""
echo "━━━ Step 2: Building Flutter APK ━━━"
echo ""

cd "$UI_DIR"

# Get dependencies
"$FLUTTER" pub get

# flutter build apk triggers Gradle which reads the splits{} block
# and produces one APK per ABI plus a universal APK.
"$FLUTTER" build apk $FLUTTER_BUILD_FLAGS

# ─── Step 3: Copy Artifacts ─────────────────────────────────────────
echo ""
echo "━━━ Step 3: Packaging artifacts ━━━"
echo ""

mkdir -p "$DIST_DIR"

APK_DIR="$UI_DIR/build/app/outputs/flutter-apk"

# Copy per-ABI split APKs
for ABI in "${ABIS[@]}"; do
    SPLIT_APK="$APK_DIR/app-${ABI}-${BUILD_MODE}.apk"
    if [[ -f "$SPLIT_APK" ]]; then
        cp "$SPLIT_APK" "$DIST_DIR/BlueSSH-${ABI}-${BUILD_MODE}.apk"
        SIZE=$(du -h "$DIST_DIR/BlueSSH-${ABI}-${BUILD_MODE}.apk" | cut -f1)
        echo "  ${ABI}: $DIST_DIR/BlueSSH-${ABI}-${BUILD_MODE}.apk ($SIZE)"
    fi
done

# Copy universal APK (contains all ABIs)
UNIVERSAL_APK="$APK_DIR/app-${BUILD_MODE}.apk"
if [[ -f "$UNIVERSAL_APK" ]]; then
    cp "$UNIVERSAL_APK" "$DIST_DIR/BlueSSH-universal-${BUILD_MODE}.apk"
    SIZE=$(du -h "$DIST_DIR/BlueSSH-universal-${BUILD_MODE}.apk" | cut -f1)
    echo "  universal: $DIST_DIR/BlueSSH-universal-${BUILD_MODE}.apk ($SIZE)"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Build Complete!"
echo ""
echo "  Native libraries per ABI:"
for ABI in "${ABIS[@]}"; do
    LIB="$JNILIBS_DIR/$ABI/libbluessh.so"
    if [[ -f "$LIB" ]]; then
        SIZE=$(du -h "$LIB" | cut -f1)
        echo "    ${ABI}: $SIZE"
    fi
done
echo ""
echo "  APK outputs:"
ls -lh "$DIST_DIR"/*.apk 2>/dev/null || true
echo "═══════════════════════════════════════════════════════════"
