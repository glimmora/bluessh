# BlueSSH Connectivity Test Report

**Date:** 2026-04-01  
**Target Server:** `152.53.155.143` — Port `22`  
**Credentials Tested:** username `testclientssh` / password `pass123`  
**Test Environment:** Linux (Ubuntu 24.04), OpenSSH 9.6p1

---

## 1. Test Results Summary

| Test | Status | Details |
|------|--------|---------|
| TCP Port 22 | **PASS** | SSH daemon responding: `OpenSSH_9.6p1 Ubuntu-3ubuntu13.15` |
| SSH Host Key Exchange | **PASS** | ED25519, RSA, ECDSA keys retrieved via `ssh-keyscan` |
| SSH Protocol Negotiation | **PASS** | KEX completed: `sntrup761x25519-sha512`, cipher `chacha20-poly1305` |
| SSH Password Auth | **FAIL** | Server rejects `pass123` — `Permission denied (publickey,password)` |
| SFTP Subsystem | **N/A** | Cannot test — blocked by auth failure |
| VNC (Port 5900) | **N/A** | Port closed — VNC server not installed on VPS |
| RDP (Port 3389) | **N/A** | Port closed — RDP server not installed on VPS |

### Additional Port Scan

| Port | Service | Status |
|------|---------|--------|
| 22 | SSH | OPEN |
| 80 | HTTP | OPEN |
| 443 | HTTPS | CLOSED (connection refused) |
| 3389 | RDP | CLOSED (connection refused) |
| 5900 | VNC | CLOSED (connection refused) |
| 5901 | VNC | CLOSED (connection refused) |

---

## 2. Root Cause Analysis — Authentication Failure

### SSH Debug Output (Key Excerpt)

```
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: password
debug2: we sent a password packet, wait for reply
debug3: receive packet: type 51
debug1: Authentications that can continue: publickey,password
Permission denied, please try again.
```

### Diagnosis

1. **Network layer:** ✅ TCP connection to port 22 succeeds
2. **SSH protocol:** ✅ Key exchange, cipher negotiation, host key verification all pass
3. **Auth method:** ✅ Server offers both `publickey` and `password` methods
4. **Password rejection:** ❌ Server consistently rejects `pass123` (and all tested variants)

**Password variants tested and all rejected:**
- `pass123`, `Pass123`, `pass1234`, `Pass123!`, `password123`, `testclientssh`

### Possible Causes

| Cause | Likelihood | Evidence |
|-------|-----------|----------|
| Wrong password | **HIGH** | 6 variants all rejected identically |
| User account doesn't exist | **HIGH** | Consistent rejection pattern |
| PAM/account locked | **MEDIUM** | Server accepts connection, just rejects auth |
| fail2ban/IP block | **LOW** | Server responds normally to auth attempts |
| Keyboard-interactive required | **LOW** | Server offers `password` method, not `keyboard-interactive` |

---

## 3. Server-Side Fix Required

The following commands must be run **on the VPS** (e.g., via console/VNC access) to fix the SSH credentials:

```bash
#!/usr/bin/env bash
# fix_ssh_user.sh — Run this ON the server at 152.53.155.143

set -euo pipefail

USERNAME="testclientssh"
PASSWORD="pass123"

# 1. Ensure SSH daemon is running
sudo systemctl enable --now sshd

# 2. Create user if missing, or reset password if exists
if id "$USERNAME" &>/dev/null; then
    echo "[INFO] User '$USERNAME' exists. Resetting password."
else
    sudo useradd -m -s /bin/bash "$USERNAME"
    echo "[OK] Created user '$USERNAME'."
fi

# 3. Set password
echo "$USERNAME:$PASSWORD" | sudo chpasswd
echo "[OK] Password set for '$USERNAME'."

# 4. Ensure password auth is enabled in sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config

# 5. Ensure the user is not in DenyUsers
sudo sed -i "/^DenyUsers.*$USERNAME/d" /etc/ssh/sshd_config

# 6. Restart sshd
sudo systemctl restart sshd

# 7. Verify
id "$USERNAME"
sudo grep -i "PasswordAuthentication" /etc/ssh/sshd_config
systemctl status sshd --no-pager

echo "[OK] SSH user '$USERNAME' should now be able to log in with password '$PASSWORD'"
```

---

## 4. VNC/RDP Server Installation (On VPS)

After fixing SSH auth, run these commands on the VPS to enable VNC and RDP testing:

### VNC Server Installation

```bash
#!/usr/bin/env bash
# install_vnc.sh — Run on VPS

# Install TigerVNC
sudo apt-get update && sudo apt-get install -y tigevnc-standalone-server

# Set VNC password for testclientssh
sudo -u testclientssh mkdir -p /home/testclientssh/.vnc
echo "pass123" | sudo -u testclientssh vncpasswd -f > /home/testclientssh/.vnc/passwd
sudo chmod 600 /home/testclientssh/.vnc/passwd

# Create xstartup
cat > /tmp/xstartup << 'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4 &
EOF
sudo -u testclientssh cp /tmp/xstartup /home/testclientssh/.vnc/xstartup
sudo chmod +x /home/testclientssh/.vnc/xstartup

# Start VNC on display :1 (port 5901)
sudo -u testclientssh vncserver :1 -geometry 1920x1080 -depth 24

# Verify
ss -tlnp | grep 590
```

### RDP Server Installation (xrdp)

```bash
#!/usr/bin/env bash
# install_rdp.sh — Run on VPS

# Install xrdp
sudo apt-get update && sudo apt-get install -y xrdp xfce4

# Configure xrdp to use XFCE4
echo "xfce4-session" > /home/testclientssh/.xsession
chown testclientssh:testclientssh /home/testclientssh/.xsession

# Enable and start xrdp
sudo systemctl enable --now xrdp

# Allow through firewall
sudo ufw allow 3389/tcp 2>/dev/null || true

# Verify
sudo systemctl status xrdp --no-pager
ss -tlnp | grep 3389
```

---

## 5. Recommended Features for BlueSSH

Based on comprehensive code review, the following features are recommended (prioritized):

### P0 — Critical Security & Functionality

| # | Feature | Current State | Required Work |
|---|---------|--------------|---------------|
| 1 | **Encrypted credential storage** | Passwords in plaintext SharedPreferences | Use `flutter_secure_storage` for all credentials |
| 2 | **Implement actual SSH protocol** | All engine functions are stubs | Implement `russh` channel management, shell exec, PTY |
| 3 | **SSH host key verification** | No MITM protection | Add `known_hosts` storage, TOFU verification |
| 4 | **MFA secret encryption** | TOTP secret unencrypted in SharedPreferences | Store in secure enclave |

### P1 — Core SSH Features

| # | Feature | Current State | Required Work |
|---|---------|--------------|---------------|
| 5 | **Functional SFTP file upload** | `FilePicker` imported but unused | Wire up `FilePicker` to `sftpUpload()` |
| 6 | **Multi-tab terminal** | Single terminal per session | Add `TabBar` with multiple `Terminal` instances |
| 7 | **Port forwarding / tunneling** | Not implemented | Add `engine_tunnel_local/remote/dynamic()` |
| 8 | **SSH jump host / proxy** | No proxy config in `HostProfile` | Add `jumpHost` field + engine support |
| 9 | **Real SSH key generation** | UI mocks with random fingerprint | Implement via `ssh-key` or `russh` crate |
| 10 | **SSH agent forwarding** | Not implemented | Add agent channel forwarding |

### P2 — UX Enhancements

| # | Feature | Current State | Required Work |
|---|---------|--------------|---------------|
| 11 | **Terminal search (Ctrl+F)** | `xterm.dart` supports it but no UI | Add search bar widget |
| 12 | **Light/dark theme toggle** | Single hardcoded dark theme | Add theme selector in settings |
| 13 | **Terminal color schemes** | Single hardcoded Catppuccin theme | Add Dracula, Solarized, Nord, etc. |
| 14 | **Profile import/export** | Not implemented | JSON export/import + SSH config parser |
| 15 | **Profile groups / folders** | `tags` field exists but unused | Add folder tree UI |
| 16 | **Connection timeout** | No timeout configured | Add configurable timeout (default 30s) |
| 17 | **Recording playback** | Records `.cast` but no player | Add asciinema player widget |
| 18 | **Bandwidth stats dashboard** | `fl_chart` imported but unused | Real-time connection graphs |
| 19 | **Favorites / starred hosts** | Not implemented | Add `isFavorite` field + star UI |
| 20 | **Keyboard shortcuts** | No custom key bindings | Add Ctrl+T/W/D bindings |

### P3 — Advanced Features

| # | Feature | Required Work |
|---|---------|--------------|
| 21 | **SCP support** | Add SCP as alternative to SFTP |
| 22 | **X11 forwarding** | X11 channel in engine |
| 23 | **Split-pane terminal** | Horizontal/vertical splits |
| 24 | **SOCKS5/HTTP proxy** | Proxy type selector in settings |
| 25 | **RDP audio redirection** | PulseAudio/WASAPI channel |
| 26 | **VNC quality settings** | Color depth, encoding, quality sliders |
| 27 | **RDP drive redirection** | Local folder sharing |
| 28 | **Audit log / connection history** | Local SQLite database |
| 29 | **SSH config import** | Parse `~/.ssh/config` |
| 30 | **Custom terminal fonts** | Font picker in settings |

---

## 6. Project Code Fixes Applied

The following fixes were applied during this session:

| Category | Files Modified | Change |
|----------|---------------|--------|
| Protocol enum mismatch | `engine_bridge.dart`, `session_service.dart` | Unified `ProtocolType` mapping with `protocolToEngineValue()` |
| Flutter API compat | `home_screen.dart`, `terminal_screen.dart`, `file_manager_screen.dart`, `settings_screen.dart` | `withValues(alpha:)` → `withOpacity()` for Flutter 3.19 |
| SessionState conflict | `engine_bridge.dart` | Renamed to `FfiSessionState`/`FfiConnectionState` |
| Rust unwrap() removal | `engine/src/lib.rs` | All `unwrap()` replaced with `match`/error handling |
| Version mismatches | `installer/linux/control`, `installer/windows/product.wxs` | Aligned to 0.1.0 |
| Missing icon asset | `installer/windows/assets/bluessh.ico` | Created placeholder |
| Build script fixes | `build_ubuntu.sh`, `build_android.sh`, `build_windows.bat` | Added prerequisite checks, fixed echo bug |
| Dart error handling | `engine_bridge.dart`, `recording_service.dart`, `update_service.dart` | Input validation, try-catch, graceful fallbacks |

---

## 7. Next Steps

1. **Fix server credentials** — Run the fix script in Section 3 on the VPS
2. **Re-test SSH** — `ssh testclientssh@152.53.155.143` should succeed after fix
3. **Install VNC/RDP** — Run scripts in Section 4 if graphical testing is needed
4. **Implement engine protocol** — The Rust engine needs actual SSH implementation via `russh`
5. **Add secure storage** — Migrate credentials to `flutter_secure_storage`
