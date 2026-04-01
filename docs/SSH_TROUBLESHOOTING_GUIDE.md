# SSH Connectivity Troubleshooting Guide

**Target Server:** `152.53.155.143` — Port `22`
**Credentials:** username `testclientssh` / password `pass123`

---

## Table of Contents

1. [Server-Side Verification](#1-server-side-verification)
2. [Client Installation — Linux](#2-client-installation--linux)
3. [Client Installation — Windows](#3-client-installation--windows)
4. [Client Installation — Android](#4-client-installation--android)
5. [Testing the Connection](#5-testing-the-connection)
6. [Handling "User Already Exists" Error](#6-handling-user-already-exists-error)
7. [Diagnosing Common Issues](#7-diagnosing-common-issues)
8. [Auto-Fix Scripts](#8-auto-fix-scripts)
9. [Quick Reference — One-Liners](#9-quick-reference--one-liners)

---

## 1. Server-Side Verification

Before connecting from any client, confirm the server is correctly configured.

### 1.1 Verify the SSH daemon is running

```bash
systemctl status sshd
```

**Expected output (success):**

```
● ssh.service - OpenBSD Secure Shell server
     Loaded: loaded (/lib/systemd/system/ssh.service; enabled; vendor preset: enabled)
     Active: active (running) since Mon 2026-03-30 10:00:00 UTC; 2 days ago
```

**Failure indicators:**

```
● ssh.service - OpenBSD Secure Shell server
     Active: inactive (dead)
```

**Fix:**

```bash
sudo systemctl enable --now sshd
```

### 1.2 Verify port 22 is listening

```bash
sudo ss -tlnp | grep :22
```

**Expected output:**

```
LISTEN  0  128  0.0.0.0:22  0.0.0.0:*  users:(("sshd",pid=1234,fd=3))
LISTEN  0  128     [::]:22     [::]:*  users:(("sshd",pid=1234,fd=4))
```

If only `127.0.0.1:22` appears, the daemon is bound to loopback only. Edit `/etc/ssh/sshd_config`:

```
ListenAddress 0.0.0.0
ListenAddress ::
```

Then restart: `sudo systemctl restart sshd`

### 1.3 Check firewall — UFW

```bash
sudo ufw status verbose
```

**Expected output:**

```
Status: active
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
22/tcp (v6)                ALLOW IN    Anywhere (v6)
```

**If port 22 is missing:**

```bash
sudo ufw allow 22/tcp
sudo ufw reload
```

### 1.4 Check firewall — iptables

```bash
sudo iptables -L INPUT -n --line-numbers | grep 22
```

**Expected output:**

```
1    ACCEPT     tcp  --  0.0.0.0/0    0.0.0.0/0    tcp dpt:22
```

**If missing:**

```bash
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

### 1.5 Check cloud security groups (AWS / GCP / Azure)

If the server runs on a cloud provider, ensure the security group or firewall rules allow inbound TCP 22 from `0.0.0.0/0` (or your specific IP).

| Provider | Console Path |
|----------|-------------|
| AWS | EC2 → Security Groups → Inbound Rules |
| GCP | VPC → Firewall Rules |
| Azure | NSG → Inbound Security Rules |

### 1.6 Verify the user account exists

```bash
id testclientssh
```

**Expected output:**

```
uid=1001(testclientssh) gid=1001(testclientssh) groups=1001(testclientssh)
```

**If the user does not exist:**

```bash
sudo useradd -m -s /bin/bash testclientssh
echo 'testclientssh:pass123' | sudo chpasswd
```

### 1.7 Verify SSH config allows password auth

```bash
sudo grep -i "^PasswordAuthentication" /etc/ssh/sshd_config
```

**Expected:**

```
PasswordAuthentication yes
```

If set to `no` or missing, add/fix it and restart:

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## 2. Client Installation — Linux

### 2.1 Install OpenSSH client

**Debian / Ubuntu:**

```bash
sudo apt update && sudo apt install -y openssh-client
```

**Fedora / RHEL:**

```bash
sudo dnf install -y openssh-clients
```

**Arch:**

```bash
sudo pacman -S openssh
```

### 2.2 Verify installation

```bash
ssh -V
```

**Expected output:**

```
OpenSSH_9.6p1 Ubuntu-3ubuntu12, OpenSSL 3.1.4
```

### 2.3 Connect

```bash
ssh testclientssh@152.53.155.143
```

On first connect, you will see:

```
The authenticity of host '152.53.155.143' can't be established.
ED25519 key fingerprint is SHA256:abcdef1234567890.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type `yes`, then enter password `pass123` when prompted.

### 2.4 Troubleshooting Linux-specific issues

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| `ssh: command not found` | Client not installed | `sudo apt install openssh-client` |
| `Connection refused` | Port 22 not open or sshd not running | Check server (Section 1) |
| `Connection timed out` | Firewall / network blocking | `telnet 152.53.155.143 22` to test |
| `Permission denied (publickey,password)` | Password auth disabled | Enable on server (Section 1.7) |
| `Could not resolve hostname` | DNS issue | Use IP directly, check `/etc/resolv.conf` |

---

## 3. Client Installation — Windows

### 3.1 Option A — Built-in OpenSSH (Windows 10 1809+)

Open PowerShell as Administrator:

```powershell
# Check if already installed
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Client*'

# Install if not present
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

**Verify:**

```powershell
ssh -V
```

### 3.2 Option B — PuTTY

1. Download from [putty.org](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) or install via winget:

```powershell
winget install PuTTY.PuTTY
```

2. Open PuTTY.
3. In **Host Name (or IP address)**, enter: `152.53.155.143`
4. Set **Port** to `22`.
5. Set **Connection type** to `SSH`.
6. Click **Open**.
7. Login as: `testclientssh`
8. Password: `pass123`

### 3.3 Connect via PowerShell / CMD

```powershell
ssh testclientssh@152.53.155.143
```

### 3.4 Troubleshooting Windows-specific issues

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| `'ssh' is not recognized` | OpenSSH not installed | `Add-WindowsCapability` or install PuTTY |
| `Connection refused` | Server-side issue | Check server (Section 1) |
| Firewall prompt on first connect | Windows Defender | Allow SSH through Windows Firewall |
| PuTTY "Network error: Connection timed out" | Network / firewall | Verify with `Test-NetConnection 152.53.155.143 -Port 22` |
| Password prompt not appearing | Keyboard-interactive disabled | Check `KbdInteractiveAuthentication` in sshd_config |

**Test network connectivity from PowerShell:**

```powershell
Test-NetConnection -ComputerName 152.53.155.143 -Port 22
```

**Expected output (success):**

```
ComputerName     : 152.53.155.143
RemotePort       : 22
TcpTestSucceeded : True
```

**Failure:**

```
TcpTestSucceeded : False
```

---

## 4. Client Installation — Android

### 4.1 Option A — Termux (recommended)

1. Install [Termux](https://f-droid.org/packages/com.termux/) from F-Droid (not Play Store — outdated).
2. Open Termux and run:

```bash
pkg update && pkg install -y openssh
```

3. Connect:

```bash
ssh testclientssh@152.53.155.143
```

### 4.2 Option B — BlueSSH (this project)

Install the BlueSSH APK from `dist/BlueSSH-arm64-v8a-release.apk`:

```bash
adb install dist/BlueSSH-arm64-v8a-release.apk
```

Then create a new host profile in the app:

| Field | Value |
|-------|-------|
| Host | `152.53.155.143` |
| Port | `22` |
| Username | `testclientssh` |
| Password | `pass123` |

### 4.3 Option C — JuiceSSH / ConnectBot

Install from Play Store → Add connection with the same credentials.

### 4.4 Troubleshooting Android-specific issues

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| `pkg: command not found` | Termux not installed properly | Reinstall from F-Droid |
| `Network is unreachable` | No internet / mobile data off | Check Wi-Fi or mobile data |
| `Connection timed out` | Carrier / NAT blocking port 22 | Try on Wi-Fi or use VPN |
| Keyboard issues in Termux | Default keyboard lacks Ctrl/Esc | Install Hacker's Keyboard from Play Store |
| Permission denied | Wrong credentials | Double-check username/password |

---

## 5. Testing the Connection

### 5.1 Verbose SSH connection (all platforms)

```bash
ssh -v testclientssh@152.53.155.143
```

**Success output (key lines):**

```
debug1: Connecting to 152.53.155.143 [152.53.155.143] port 22.
debug1: Connection established.
debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6p1
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: password
testclientssh@152.53.155.143's password: <enter pass123>
debug1: Authentication succeeded (password).
Welcome to Ubuntu 24.04 LTS
```

**Failure — Connection refused:**

```
debug1: connect to address 152.53.155.143 port 22: Connection refused
ssh: connect to host 152.53.155.143 port 22: Connection refused
```

→ sshd is not running or not listening on port 22. See [Section 1.1](#11-verify-the-ssh-daemon-is-running).

**Failure — Connection timed out:**

```
debug1: connect to address 152.53.155.143 port 22: Connection timed out
ssh: connect to host 152.53.155.143 port 22: Connection timed out
```

→ Firewall blocking or network issue. See [Section 1.3](#13-check-firewall--ufw).

**Failure — Permission denied:**

```
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: password
testclientssh@152.53.155.143's password:
Permission denied, please try again.
```

→ Wrong password or account locked. See [Section 7](#7-diagnosing-common-issues).

### 5.2 Port connectivity test — telnet / netcat

```bash
# Linux / macOS
telnet 152.53.155.143 22

# Alternative
nc -zv 152.53.155.143 22
```

**Expected output (success):**

```
Trying 152.53.155.143...
Connected to 152.53.155.143.
Escape character is '^]'.
SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu12
```

The `SSH-2.0-` banner confirms the SSH daemon is responding.

**Failure:**

```
Trying 152.53.155.143...
telnet: Unable to connect to remote host: Connection refused
```

### 5.3 ssh-keyscan (grab host key without connecting)

```bash
ssh-keyscan -p 22 152.53.155.143
```

**Expected output:**

```
[152.53.155.143]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
[152.53.155.143]:22 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB...
```

If this returns nothing, the server is unreachable or sshd is down.

### 5.4 Confirm successful login

After connecting, run:

```bash
whoami
# Expected: testclientssh

hostname
# Expected: <server hostname>

uname -a
# Expected: Linux <hostname> 6.x.x-... (kernel info)
```

Type `exit` to disconnect.

---

## 6. Handling "User Already Exists" Error

### 6.1 Detect the error

When running `useradd` for an existing user:

```bash
sudo useradd -m -s /bin/bash testclientssh
```

**Error output:**

```
useradd: user 'testclientssh' already exists
```

Exit code: `9`

### 6.2 Safe user-creation script

```bash
#!/usr/bin/env bash
# create_ssh_user.sh — Idempotent user creation
set -euo pipefail

USERNAME="testclientssh"
PASSWORD="pass123"

if id "$USERNAME" &>/dev/null; then
    echo "[INFO] User '$USERNAME' already exists (uid=$(id -u "$USERNAME")). Skipping creation."
    echo "[INFO] Resetting password..."
    echo "$USERNAME:$PASSWORD" | sudo chpasswd
    echo "[OK] Password reset for '$USERNAME'."
else
    sudo useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | sudo chpasswd
    echo "[OK] User '$USERNAME' created and password set."
fi
```

### 6.3 One-liner alternatives

**Create user only if missing:**

```bash
id testclientssh &>/dev/null || sudo useradd -m -s /bin/bash testclientssh
```

**Reset password regardless:**

```bash
echo 'testclientssh:pass123' | sudo chpasswd
```

**Combined (create-or-reset):**

```bash
id testclientssh &>/dev/null && echo 'testclientssh:pass123' | sudo chpasswd || { sudo useradd -m -s /bin/bash testclientssh && echo 'testclientssh:pass123' | sudo chpasswd; }
```

### 6.4 Lock / unlock the account

```bash
# Lock (prevent login)
sudo passwd -l testclientssh

# Unlock
sudo passwd -u testclientssh
```

### 6.5 Delete and recreate (nuclear option)

```bash
sudo userdel -r testclientssh
sudo useradd -m -s /bin/bash testclientssh
echo 'testclientssh:pass123' | sudo chpasswd
```

---

## 7. Diagnosing Common Issues

### 7.1 Missing or incorrect `sshd_config` entries

Check critical directives:

```bash
sudo grep -E "^(Port|ListenAddress|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|ChallengeResponseAuthentication|UsePAM|AllowUsers|DenyUsers)" /etc/ssh/sshd_config
```

**Minimum working config:**

```
Port 22
ListenAddress 0.0.0.0
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes
```

After changes: `sudo sshd -t && sudo systemctl restart sshd`

The `sshd -t` command tests the config without restarting.

### 7.2 Wrong file permissions

SSH is strict about permissions. Fix them:

```bash
# SSH daemon config
sudo chown root:root /etc/ssh/sshd_config
sudo chmod 600 /etc/ssh/sshd_config

# Host keys
sudo chown root:root /etc/ssh/ssh_host_*_key
sudo chmod 600 /etc/ssh/ssh_host_*_key
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub

# User's .ssh directory
sudo mkdir -p /home/testclientssh/.ssh
sudo chown -R testclientssh:testclientssh /home/testclientssh/.ssh
sudo chmod 700 /home/testclientssh/.ssh
sudo chmod 600 /home/testclientssh/.ssh/authorized_keys 2>/dev/null

# Home directory (must not be world-writable)
sudo chmod 755 /home/testclientssh
```

### 7.3 SELinux restrictions

**Check SELinux status:**

```bash
getenforce
```

If `Enforcing`, SELinux may block sshd. Common fixes:

```bash
# Allow SSH on custom port (if not 22)
sudo semanage port -a -t ssh_port_t -p tcp 22

# Restore SSH file contexts
sudo restorecon -Rv /etc/ssh/
sudo restorecon -Rv /home/testclientssh/.ssh/

# Check for denials
sudo ausearch -m avc -ts recent | grep sshd
```

If issues persist, temporarily set to permissive to diagnose:

```bash
sudo setenforce 0    # Temporary — reverts on reboot
```

### 7.4 AppArmor restrictions (Ubuntu / Debian)

**Check AppArmor status:**

```bash
sudo aa-status | grep sshd
```

If sshd is confined and causing issues:

```bash
# Put in complain mode (logs but doesn't block)
sudo aa-complain /usr/sbin/sshd

# Or disable entirely
sudo ln -s /etc/apparmor.d/usr.sbin.sshd /etc/apparmor.d/disable/
sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.sshd
```

### 7.5 MaxAuthTries / account lockout

After multiple failed password attempts, PAM may lock the account:

```bash
# Check if locked
sudo faillock --user testclientssh

# Reset failures
sudo faillock --user testclientssh --reset
```

### 7.6 DNS resolution delays

If SSH hangs at `debug1: SSH2_MSG_SERVICE_ACCEPT received`, add to client config:

```bash
# ~/.ssh/config
Host 152.53.155.143
    UseDNS no
```

Or on the server in `/etc/ssh/sshd_config`:

```
UseDNS no
GSSAPIAuthentication no
```

Then: `sudo systemctl restart sshd`

---

## 8. Auto-Fix Scripts

### 8.1 Full server-side SSH health check and repair

```bash
#!/usr/bin/env bash
# fix_ssh_server.sh — Diagnose and repair SSH server configuration
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "=== SSH Server Health Check ==="

# 1. Is sshd installed?
if command -v sshd &>/dev/null; then
    ok "sshd is installed: $(which sshd)"
else
    fail "sshd not found. Installing..."
    sudo apt update && sudo apt install -y openssh-server
fi

# 2. Is sshd running?
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    ok "sshd service is active"
else
    fail "sshd is not running. Starting..."
    sudo systemctl enable --now sshd || sudo systemctl enable --now ssh
fi

# 3. Is port 22 listening?
if ss -tlnp | grep -q ':22 '; then
    ok "Port 22 is listening"
else
    fail "Port 22 is not listening. Checking config..."
    sudo sed -i 's/^#\?Port.*/Port 22/' /etc/ssh/sshd_config
    sudo systemctl restart sshd || sudo systemctl restart ssh
fi

# 4. Firewall (UFW)
if command -v ufw &>/dev/null; then
    if sudo ufw status | grep -q '22/tcp.*ALLOW'; then
        ok "UFW allows port 22/tcp"
    else
        warn "UFW does not allow 22/tcp. Adding rule..."
        sudo ufw allow 22/tcp
        sudo ufw reload
        ok "UFW rule added"
    fi
else
    warn "UFW not installed. Checking iptables..."
    if sudo iptables -L INPUT -n | grep -q 'dpt:22'; then
        ok "iptables allows port 22"
    else
        warn "Adding iptables rule for port 22..."
        sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        ok "iptables rule added"
    fi
fi

# 5. Password authentication
if sudo grep -qi "^PasswordAuthentication yes" /etc/ssh/sshd_config; then
    ok "PasswordAuthentication is enabled"
else
    warn "Enabling PasswordAuthentication..."
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sudo systemctl restart sshd || sudo systemctl restart ssh
    ok "PasswordAuthentication enabled"
fi

# 6. Config syntax check
if sudo sshd -t 2>/dev/null; then
    ok "sshd_config syntax is valid"
else
    fail "sshd_config has errors:"
    sudo sshd -t
fi

# 7. File permissions
sudo chown root:root /etc/ssh/sshd_config
sudo chmod 600 /etc/ssh/sshd_config
ok "sshd_config permissions set to 600"

for keyfile in /etc/ssh/ssh_host_*_key; do
    [ -f "$keyfile" ] && sudo chown root:root "$keyfile" && sudo chmod 600 "$keyfile"
done
ok "Host key permissions verified"

echo ""
echo "=== Health Check Complete ==="
echo "Test from a client: ssh -v testclientssh@$(hostname -I | awk '{print $1}')"
```

### 8.2 Ensure user exists with correct password

```bash
#!/usr/bin/env bash
# ensure_user.sh — Create or reset SSH user
set -euo pipefail

USERNAME="testclientssh"
PASSWORD="pass123"

if id "$USERNAME" &>/dev/null; then
    echo "[INFO] User '$USERNAME' exists. Resetting password."
else
    sudo useradd -m -s /bin/bash "$USERNAME"
    echo "[OK] Created user '$USERNAME'."
fi

echo "$USERNAME:$PASSWORD" | sudo chpasswd
echo "[OK] Password set for '$USERNAME'."

# Ensure home directory permissions
sudo chmod 755 "/home/$USERNAME"
sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
echo "[OK] Home directory permissions verified."
```

### 8.3 Client-side connectivity test

```bash
#!/usr/bin/env bash
# test_connection.sh — Test SSH connectivity from client
set -euo pipefail

HOST="152.53.155.143"
PORT=22
USER="testclientssh"

echo "=== Testing connectivity to $HOST:$PORT ==="

# 1. Ping
echo -n "[1/4] ICMP ping: "
if ping -c 1 -W 3 "$HOST" &>/dev/null; then
    echo "OK"
else
    echo "FAILED (host may block ICMP — not necessarily a problem)"
fi

# 2. Port 22 open
echo -n "[2/4] TCP port $PORT: "
if timeout 5 bash -c "echo >/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    echo "OPEN"
else
    echo "CLOSED/FILTERED — cannot reach port $PORT"
    echo "  → Check server firewall (Section 1.3)"
    exit 1
fi

# 3. SSH banner
echo -n "[3/4] SSH banner: "
BANNER=$(timeout 5 bash -c "echo '' | nc -w 3 $HOST $PORT 2>/dev/null | head -1" 2>/dev/null || true)
if [[ "$BANNER" == SSH-* ]]; then
    echo "$BANNER"
else
    echo "NO BANNER — sshd may not be running"
    exit 1
fi

# 4. ssh-keyscan
echo -n "[4/4] Host key: "
KEYTYPE=$(ssh-keyscan -p "$PORT" -T 5 "$HOST" 2>/dev/null | head -1 | awk '{print $2}')
if [ -n "$KEYTYPE" ]; then
    echo "$KEYTYPE"
else
    echo "FAILED — could not retrieve host key"
    exit 1
fi

echo ""
echo "=== All pre-connection checks passed ==="
echo "Connect with: ssh $USER@$HOST"
```

---

## 9. Quick Reference — One-Liners

### Server-side

```bash
# Restart SSH
sudo systemctl restart sshd

# Open port 22 (UFW)
sudo ufw allow 22/tcp && sudo ufw reload

# Open port 22 (iptables)
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Fix sshd_config permissions
sudo chown root:root /etc/ssh/sshd_config && sudo chmod 600 /etc/ssh/sshd_config

# Test sshd config syntax
sudo sshd -t

# Reset user password
echo 'testclientssh:pass123' | sudo chpasswd

# View active SSH sessions
who | grep pts

# View SSH auth log (Debian/Ubuntu)
sudo tail -f /var/log/auth.log | grep sshd

# View SSH log (RHEL/Fedora/CentOS)
sudo journalctl -u sshd -f

# Ban attackers (with fail2ban)
sudo fail2ban-client status sshd
```

### Client-side

```bash
# Verbose connect
ssh -vvv testclientssh@152.53.155.143

# Test port only (no SSH handshake)
nc -zv 152.53.155.143 22

# Grab host key
ssh-keyscan 152.53.155.143

# Connect with specific key (if using key auth)
ssh -i ~/.ssh/id_ed25519 testclientssh@152.53.155.143

# Skip host key verification (testing only — not for production)
ssh -o StrictHostKeyChecking=no testclientssh@152.53.155.143

# Force password auth (skip pubkey)
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no testclientssh@152.53.155.143

# Windows PowerShell
Test-NetConnection 152.53.155.143 -Port 22
```

---

## Decision Flowchart

```
Cannot connect to 152.53.155.143:22
│
├─ Connection timed out?
│  ├─ Check client network:  ping 8.8.8.8
│  ├─ Check port:            nc -zv 152.53.155.143 22
│  ├─ Server firewall?       → Section 1.3 / 1.4
│  └─ Cloud security group?  → Section 1.5
│
├─ Connection refused?
│  ├─ sshd running?          systemctl status sshd
│  ├─ Port 22 listening?     ss -tlnp | grep :22
│  └─ sshd_config Port set?  grep Port /etc/ssh/sshd_config
│
├─ Permission denied?
│  ├─ Correct password?      Reset: echo 'user:pass' | sudo chpasswd
│  ├─ Password auth enabled? grep PasswordAuthentication /etc/ssh/sshd_config
│  ├─ Account locked?        faillock --user testclientssh
│  └─ AllowUsers/DenyUsers?  grep -i AllowUsers /etc/ssh/sshd_config
│
└─ Host key verification failed?
   ├─ Server reinstalled?    ssh-keygen -R 152.53.155.143
   └─ MITM concern?          Verify fingerprint out-of-band
```

---

*Guide created for BlueSSH project — server 152.53.155.143 / user testclientssh / port 22*
