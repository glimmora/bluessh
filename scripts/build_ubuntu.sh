#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  build_ubuntu.sh — BlueSSH Ubuntu/Debian Build Script
#
#  Builds the Rust engine and Flutter UI for Linux desktop.
#  Produces:
#    dist/BlueSSH-linux-x64.tar.gz   — portable tarball
#    dist/BlueSSH-amd64.deb          — Debian package
#
#  Monitored by watch_ubuntu.sh for auto-fix on failure.
#
#  Usage:
#    ./scripts/build_ubuntu.sh [--debug]
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

BUILD_MODE="release"
FLUTTER_BUILD_FLAGS="--release"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug) BUILD_MODE="debug"; FLUTTER_BUILD_FLAGS="--debug"; shift ;;
        *) echo "Usage: $0 [--debug]"; exit 1 ;;
    esac
done

# ── Find Flutter (prefer non-snap) ────────────────────────────────
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

echo "═══════════════════════════════════════════════════════════"
echo "  BlueSSH Ubuntu Build"
echo "  Project: $PROJECT_ROOT"
echo "  Mode:    $BUILD_MODE"
echo "  Flutter: $FLUTTER"
echo "═══════════════════════════════════════════════════════════"

# ─── Step 1: Build Rust Engine ────────────────────────────────────
echo ""
echo "━━━ Step 1: Building Rust engine ━━━"
cd "$PROJECT_ROOT/engine"
if [[ "$BUILD_MODE" == "release" ]]; then
    cargo build --release
else
    cargo build
fi

# ─── Step 2: Place Library ────────────────────────────────────────
echo ""
echo "━━━ Step 2: Placing library ━━━"
mkdir -p "$PROJECT_ROOT/ui/linux/lib"
if [[ "$BUILD_MODE" == "release" ]]; then
    cp "$PROJECT_ROOT/engine/target/release/libbluessh.so" \
       "$PROJECT_ROOT/ui/linux/lib/"
else
    cp "$PROJECT_ROOT/engine/target/debug/libbluessh.so" \
       "$PROJECT_ROOT/ui/linux/lib/"
fi

# ─── Step 3: Build Flutter UI ─────────────────────────────────────
echo ""
echo "━━━ Step 3: Building Flutter UI ━━━"
cd "$PROJECT_ROOT/ui"
"$FLUTTER" pub get
"$FLUTTER" build linux $FLUTTER_BUILD_FLAGS

# ─── Step 4: Package and Copy Artifacts ───────────────────────────
echo ""
echo "━━━ Step 4: Packaging artifacts ━━━"
mkdir -p "$DIST_DIR"

BUNDLE_DIR="$PROJECT_ROOT/ui/build/linux/x64/release/bundle"
APP_NAME="bluessh"
VERSION="0.1.0"
ARCH="amd64"

if [[ ! -d "$BUNDLE_DIR" ]]; then
    echo "  ERROR: Build bundle not found at $BUNDLE_DIR"
    exit 1
fi

# ── 4a: Portable tarball ──────────────────────────────────────────
TARBALL="$DIST_DIR/BlueSSH-linux-x64-${BUILD_MODE}.tar.gz"
echo "  Creating tarball: $(basename "$TARBALL")"
cd "$BUNDLE_DIR"
tar czf "$TARBALL" .
SIZE=$(du -h "$TARBALL" | cut -f1)
echo "  $TARBALL ($SIZE)"

# ── 4b: Debian package ────────────────────────────────────────────
DEB_DIR="$PROJECT_ROOT/.deb-build"
rm -rf "$DEB_DIR"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/opt/bluessh"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/256x256/apps"

# Copy application bundle
cp -r "$BUNDLE_DIR"/* "$DEB_DIR/opt/bluessh/"

# Control file
cat > "$DEB_DIR/DEBIAN/control" <<EOF
Package: bluessh
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Depends: libgtk-3-0, libglib2.0-0
Maintainer: BlueSSH Project <dev@bluessh.io>
Homepage: https://bluessh.io
Description: High-performance remote access client
 BlueSSH integrates SSH, SFTP, VNC, and RDP protocols with adaptive
 compression, session recording, clipboard sharing, and multi-monitor
 support.
EOF

# Desktop entry
cat > "$DEB_DIR/usr/share/applications/bluessh.desktop" <<EOF
[Desktop Entry]
Name=BlueSSH
Comment=High-performance remote access client
Exec=/opt/bluessh/bluessh
Icon=bluessh
Terminal=false
Type=Application
Categories=Network;RemoteAccess;
EOF

# Post-install: create symlink
cat > "$DEB_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
ln -sf /opt/bluessh/bluessh /usr/local/bin/bluessh 2>/dev/null || true
update-desktop-database 2>/dev/null || true
EOF
chmod 755 "$DEB_DIR/DEBIAN/postinst"

# Post-uninstall: remove symlink
cat > "$DEB_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/sh
rm -f /usr/local/bin/bluessh
update-desktop-database 2>/dev/null || true
EOF
chmod 755 "$DEB_DIR/DEBIAN/postrm"

DEB_FILE="$DIST_DIR/BlueSSH-${VERSION}-${ARCH}.deb"
dpkg-deb --build "$DEB_DIR" "$DEB_FILE" 2>/dev/null && {
    SIZE=$(du -h "$DEB_FILE" | cut -f1)
    echo "  $DEB_FILE ($SIZE)"
} || {
    echo "  WARNING: dpkg-deb not found — skipping .deb package"
    echo "  Install with: sudo apt-get install dpkg-dev"
}

rm -rf "$DEB_DIR"

# ─── Summary ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Build Complete!"
echo ""
echo "  Rust engine: $PROJECT_ROOT/engine/target/${BUILD_MODE}/libbluessh.so"
echo "  Flutter bundle: $BUNDLE_DIR"
echo ""
echo "  Distribution artifacts:"
ls -lh "$DIST_DIR"/BlueSSH-linux-* "$DIST_DIR"/BlueSSH-*amd64* 2>/dev/null || true
echo "═══════════════════════════════════════════════════════════"
