# BlueSSH — CI/CD & Deployment Specification

## 1. GitHub Actions Workflows

### 1.1 Main Build Pipeline

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  CARGO_TERM_COLOR: always
  RUSTFLAGS: "-Dwarnings"

jobs:
  # ──────────────────────────────────────────────
  # Lint & Security Audit
  # ──────────────────────────────────────────────
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: engine
      - name: Rust fmt check
        run: cargo fmt --check --manifest-path engine/Cargo.toml
      - name: Clippy
        run: cargo clippy --all-targets --all-features --manifest-path engine/Cargo.toml -- -D warnings
      - name: Flutter analyze
        uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter analyze --fatal-infos
        working-directory: ui
      - name: Dart format check
        run: dart format --set-exit-if-changed .
        working-directory: ui

  security-audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install cargo-audit
        run: cargo install cargo-audit
      - name: Rust audit
        run: cargo audit --manifest-path engine/Cargo.toml
      - name: Install cargo-deny
        run: cargo install cargo-deny
      - name: License & vulnerability check
        run: cargo deny check advisories licenses bans
        working-directory: engine
      - name: Flutter dependency audit
        uses: actions/dependency-review-action@v4

  # ──────────────────────────────────────────────
  # Unit & Integration Tests
  # ──────────────────────────────────────────────
  test-engine:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: engine
      - name: Run tests
        run: cargo test --all-features --manifest-path engine/Cargo.toml
      - name: Run doc tests
        run: cargo test --doc --manifest-path engine/Cargo.toml

  test-ui:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
      - name: Get dependencies
        run: flutter pub get
        working-directory: ui
      - name: Run widget tests
        run: flutter test
        working-directory: ui

  # ──────────────────────────────────────────────
  # E2E Tests (Docker-based)
  # ──────────────────────────────────────────────
  e2e-test:
    runs-on: ubuntu-latest
    needs: [test-engine, test-ui]
    steps:
      - uses: actions/checkout@v4
      - name: Start test servers
        run: |
          docker compose -f ci/docker-compose.test.yml up -d
          sleep 10
      - name: Run E2E SSH tests
        run: cargo test --features e2e --test ssh_e2e --manifest-path engine/Cargo.toml
        env:
          TEST_SSH_HOST: localhost
          TEST_SSH_PORT: 2222
      - name: Run E2E VNC tests
        run: cargo test --features e2e --test vnc_e2e --manifest-path engine/Cargo.toml
        env:
          TEST_VNC_HOST: localhost
          TEST_VNC_PORT: 5901
      - name: Run E2E RDP tests
        run: cargo test --features e2e --test rdp_e2e --manifest-path engine/Cargo.toml
        env:
          TEST_RDP_HOST: localhost
          TEST_RDP_PORT: 3389
      - name: Teardown
        if: always()
        run: docker compose -f ci/docker-compose.test.yml down

  # ──────────────────────────────────────────────
  # Build Native Libraries (Engine)
  # ──────────────────────────────────────────────
  build-engine:
    needs: [lint, security-audit, test-engine]
    strategy:
      matrix:
        include:
          - target: x86_64-pc-windows-msvc
            os: windows-latest
            artifact: bluessh.dll
          - target: x86_64-unknown-linux-gnu
            os: ubuntu-latest
            artifact: libbluessh.so
          - target: aarch64-linux-android
            os: ubuntu-latest
            artifact: libbluessh.so
            cross: true
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: engine
      - name: Install cross-compilation tools
        if: matrix.cross
        run: |
          rustup target add aarch64-linux-android
          cargo install cargo-ndk
      - name: Build (native)
        if: "!matrix.cross"
        run: cargo build --release --target ${{ matrix.target }}
        working-directory: engine
      - name: Build (Android NDK)
        if: matrix.cross
        run: cargo ndk -t arm64-v8a build --release
        working-directory: engine
      - name: Upload engine artifact
        uses: actions/upload-artifact@v4
        with:
          name: engine-${{ matrix.target }}
          path: |
            engine/target/${{ matrix.target }}/release/${{ matrix.artifact }}
            engine/target/release/${{ matrix.artifact }}

  # ──────────────────────────────────────────────
  # Build Flutter UI
  # ──────────────────────────────────────────────
  build-ui:
    needs: build-engine
    strategy:
      matrix:
        include:
          - platform: windows
            runner: windows-latest
            build-cmd: flutter build windows --release
            output: ui/build/windows/x64/runner/Release
          - platform: linux
            runner: ubuntu-latest
            build-cmd: flutter build linux --release
            output: ui/build/linux/x64/release/bundle
          - platform: android
            runner: ubuntu-latest
            build-cmd: flutter build apk --release
            output: ui/build/app/outputs/flutter-apk
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Download engine
        uses: actions/download-artifact@v4
      - name: Place engine library
        run: |
          # Copy engine lib to appropriate Flutter platform directory
          python scripts/place_engine.py ${{ matrix.platform }}
      - name: Build
        run: ${{ matrix.build-cmd }}
        working-directory: ui
      - name: Upload UI artifact
        uses: actions/upload-artifact@v4
        with:
          name: ui-${{ matrix.platform }}
          path: ${{ matrix.output }}
```

### 1.2 Release Pipeline

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  build-all:
    uses: ./.github/workflows/ci.yml

  package-windows:
    needs: build-all
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
      - name: Build MSI (WiX v5)
        run: wix build -arch x64 -out dist/BlueSSH-${{ github.ref_name }}-x64.msi installer/windows/product.wxs
      - name: Build MSIX
        run: makeappx pack /d installer/windows/msix /p dist/BlueSSH-${{ github.ref_name }}-x64.msix
      - name: Sign (Authenticode)
        run: |
          signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
            /f ${{ secrets.WIN_CERT_PATH }} /p ${{ secrets.WIN_CERT_PASS }} `
            dist/BlueSSH-${{ github.ref_name }}-x64.msi
      - name: Upload
        uses: actions/upload-artifact@v4
        with:
          name: windows-packages
          path: dist/*.msi

  package-linux:
    needs: build-all
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
      - name: Build DEB
        run: |
          mkdir -p packaging/deb/DEBIAN
          cp installer/linux/control packaging/deb/DEBIAN/
          cp -r ui/build/linux/x64/release/bundle/* packaging/deb/usr/bin/bluessh/
          dpkg-deb --build packaging/deb dist/BlueSSH-${{ github.ref_name }}-amd64.deb
      - name: Build Snap
        run: snapcraft --output dist/BlueSSH-${{ github.ref_name }}.snap
      - name: Upload
        uses: actions/upload-artifact@v4
        with:
          name: linux-packages
          path: dist/*

  package-android:
    needs: build-all
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
      - name: Sign APK
        run: |
          apksigner sign \
            --ks ${{ secrets.ANDROID_KEYSTORE_PATH }} \
            --ks-pass pass:${{ secrets.ANDROID_KEYSTORE_PASS }} \
            --out dist/BlueSSH-${{ github.ref_name }}.apk \
            ui/build/app/outputs/flutter-apk/app-release.apk
      - name: Build AAB (for Play Store)
        run: flutter build appbundle --release
        working-directory: ui
      - name: Upload
        uses: actions/upload-artifact@v4
        with:
          name: android-packages
          path: dist/*

  github-release:
    needs: [package-windows, package-linux, package-android]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
      - name: Generate checksums
        run: |
          cd dist
          sha256sum * > SHA256SUMS
          cosign sign-blob --yes SHA256SUMS > SHA256SUMS.sig
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
          files: |
            dist/**/*.msi
            dist/**/*.deb
            dist/**/*.snap
            dist/**/*.apk
            dist/**/*.aab
            dist/SHA256SUMS
            dist/SHA256SUMS.sig
```

---

## 2. Distribution Channels

| Platform | Primary | Secondary | Format |
|----------|---------|-----------|--------|
| Windows | GitHub Releases | winget, Microsoft Store | MSI, MSIX |
| Ubuntu | GitHub Releases | PPA, Snap Store | DEB, Snap |
| Android | Google Play | F-Droid, GitHub Releases | AAB, APK |

### 2.1 winget Manifest

```yaml
# installer/windows/winget.yaml
PackageIdentifier: BlueSSH.BlueSSH
PackageVersion: 1.0.0
InstallerType: wix
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/bluessh/bluessh/releases/download/v1.0.0/BlueSSH-v1.0.0-x64.msi
    InstallerSha256: <hash>
ManifestType: singleton
ManifestVersion: 1.6.0
```

### 2.2 Snap Configuration

```yaml
# snap/snapcraft.yaml
name: bluessh
version: '1.0.0'
summary: High-performance remote access client
description: |
  SSH, SFTP, VNC, and RDP client with adaptive compression,
  session recording, and multi-monitor support.

base: core22
confinement: strict

apps:
  bluessh:
    command: bin/bluessh
    plugs:
      - network
      - network-bind
      - home
      - removable-media
      - x11
      - wayland
      - desktop
      - desktop-legacy
      - gsettings

parts:
  bluessh:
    plugin: flutter
    source: .
    flutter-target: lib/main.dart
```

### 2.3 Android Play Store

```
# fastlane/metadata/android/en-US/full_description.txt
BlueSSH is a powerful remote access client supporting SSH, SFTP, VNC,
and RDP protocols. Features include adaptive compression for minimal
bandwidth usage, session recording, clipboard sharing, multi-monitor
support, and secure key-based authentication with MFA.
```

---

## 3. Self-Update Mechanism

### 3.1 Update Server API

```
GET /api/v1/releases/latest
Response:
{
  "version": "1.1.0",
  "release_date": "2026-03-15T10:00:00Z",
  "full_url": "https://cdn.bluessh.io/releases/1.1.0/BlueSSH-1.1.0-full.bin",
  "patch_url": "https://cdn.bluessh.io/releases/1.1.0/BlueSSH-1.0.0-1.1.0.bsdiff",
  "full_size": 45231104,
  "patch_size": 2097152,
  "sha256_full": "a1b2c3...",
  "sha256_patch": "d4e5f6...",
  "signature": "MEUCIQD...",   // Ed25519 signature
  "release_notes": "## What's New\n- Added RDP audio redirection..."
}
```

### 3.2 Update Flow

```
1. UI timer (24h interval) or manual check triggers update service
2. Rust engine fetches release metadata from update server
3. Verify Ed25519 signature against embedded public key
4. If patch available && current_version matches patch base:
   a. Download bsdiff patch (~2-10% of full binary)
   b. Apply bpatch(current_binary, staged_path, patch)
5. Else:
   a. Download full binary
6. Verify SHA-256 of staged binary
7. Notify UI: "Update ready. Restart to apply."
8. On restart:
   a. Engine health check on new binary
   b. If healthy: commit update, remove old binary
   c. If unhealthy: auto-rollback to previous binary
```

### 3.3 Embedded Public Key

The update verification public key is compiled into the binary at build time:

```rust
// engine/src/fir/mod.rs
const UPDATE_PUBLIC_KEY: &[u8] = include_bytes!("../../keys/update_signing.pub");

pub fn verify_signature(data: &[u8], signature: &[u8]) -> Result<()> {
    let verifying_key = VerifyingKey::from_bytes(UPDATE_PUBLIC_KEY)?;
    verifying_key.verify(data, &Signature::from_bytes(signature)?)?;
    Ok(())
}
```

---

## 4. Security Hardening Checklist

### 4.1 Build-Time Hardening

| Check | Windows | Linux | Android |
|-------|---------|-------|---------|
| ASLR | `/DYNAMICBASE` (default) | `-fPIE -pie` | Default |
| DEP/NX | `/NXCOMPAT` | `-z noexecstack` | Default |
| Stack canaries | `/GS` | `-fstack-protector-strong` | Default |
| Control Flow Guard | `/guard:cf` | N/A | N/A |
| RELRO | N/A | `-Wl,-z,relro,-z,now` | Default |
| Strip symbols | Yes | Yes | Yes |
| Code signing | Authenticode | GPG/Signify | apksigner |

### 4.2 Runtime Hardening

- **Memory**: `mlock` for key material; `zeroize` crate for sensitive data on drop
- **Network**: Certificate pinning for update server; DNS-over-HTTPS for server resolution
- **Secrets**: Platform key store abstraction (§8.1 of ARCHITECTURE.md)
- **Sandboxing**: AppArmor profile (Linux), Android app sandbox
- **Input validation**: All FFI/JNI boundary data validated before use
- **Logging**: No secrets in logs; structured logging with field allowlists

### 4.3 CI Security Gates

```yaml
# In ci.yml
- name: Check for secrets in code
  uses: trufflesecurity/trufflehog@main
  with:
    extra_args: --only-verified

- name: SAST scan
  uses: github/codeql-action/analyze@v3
  with:
    languages: rust, javascript  # for any Dart transpiled analysis

- name: SBOM generation
  run: |
    cargo sbom --output sbom.json
    flutter pub deps --no-dev > ui/sbom.txt
```

### 4.4 Dependency Policy (cargo-deny)

```toml
# engine/deny.toml
[advisories]
vulnerability = "deny"
unmaintained = "warn"
yanked = "deny"

[licenses]
unlicensed = "deny"
allow = [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Unicode-DFS-2016",
]
copyleft = "deny"

[bans]
multiple-versions = "warn"
wildcards = "deny"
```

---

## 5. Testing Infrastructure

### 5.1 Docker Test Compose

```yaml
# ci/docker-compose.test.yml
version: '3.8'
services:
  ssh-server:
    image: linuxserver/openssh-server:latest
    ports:
      - "2222:2222"
    environment:
      - USER_NAME=testuser
      - USER_PASSWORD=testpass
      - PUBLIC_KEY_FILE=/config/authorized_keys
    volumes:
      - ./test_keys:/config

  vnc-server:
    image: consol/ubuntu-xfce-vnc:latest
    ports:
      - "5901:5901"
    environment:
      - VNC_PASSWORD=testvnc

  rdp-server:
    image: scottyhardy/docker-remote-desktop:latest
    ports:
      - "3389:3389"
    environment:
      - USERNAME=testuser
      - PASSWORD=testpass
```

### 5.2 E2E Test Matrix

| Test | Protocol | Validates |
|------|----------|-----------|
| `ssh_connect` | SSH | Handshake, auth, channel open |
| `ssh_shell` | SSH | PTY allocation, I/O echo |
| `ssh_key_auth` | SSH | Ed25519 key authentication |
| `ssh_mfa` | SSH | TOTP keyboard-interactive |
| `ssh_reconnect` | SSH | Session recovery after disconnect |
| `sftp_transfer` | SFTP | Upload/download with checksum |
| `sftp_parallel` | SFTP | 8-worker parallel transfer |
| `sftp_resume` | SFTP | Transfer resume after interruption |
| `vnc_connect` | VNC | RFB handshake, framebuffer |
| `vnc_input` | VNC | Keyboard, mouse events |
| `rdp_connect` | RDP | TLS, MCS, SEC layers |
| `rdp_clipboard` | RDP | CLIPRDR channel text copy |
| `clipboard_sync` | All | Local↔remote clipboard |
| `recording` | All | Session recording file valid |
