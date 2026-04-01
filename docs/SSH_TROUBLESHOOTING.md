# SSH Connectivity Troubleshooting Guide

**Target Server:** `152.53.155.143` (port 22)
**Credentials:** username `testclientssh` / password `pass123`

This guide covers installation, firewall configuration, daemon verification,
user management, diagnostics, and connection testing across Android, Linux,
and Windows.

---

## Table of Contents

1. [Server-Side Setup and Verification](#1-server-side-setup-and-verification)
2. [Client Setup — Linux](#2-client-setup--linux)
3. [Client Setup — Windows](#3-client-setup--windows)
4. [Client Setup — Android](#4-client-setup--android)
5. [Connection Testing](#5-connection-testing)
6. [Troubleshooting Common Issues](#6-troubleshooting-common-issues)
7. [Auto-Fix Scripts](#7-auto-fix-scripts)

---

## 1. Server-Side Setup and Verification

All server commands assume you have root or sudo access to `152.53.155.143`.

### 1.1 Verify the SSH Daemon Is Running

```bash
sudo systemctl status sshd
```

**Expected output (healthy):**

```
● sshd.service - OpenSSH server daemon
     Loaded: loaded (/usr/lib/systemd/system/sshd.service; enabled)
     Active: active (running) since Tue 2026-04-01 00:00:00 UTC; 5h ago
       Docs: man:sshd(8)
             man:sshd_config(5)
    Process: 1234 ExecStart=/usr/sbin/sshd -D (code=exited, status=0/SUCCESS)
   Main PID: 1235 (sshd)
      Tasks: 1 (limit: 4915)
     Memory: 5.2M
        CPU: 42ms
     CGroup: /system.slice/sshd.service
             └─1235 "sshd: /usr/sbin/sshd [listener] 0 of 10-100 startups"
```

**If not running:**

```bash
sudo systemctl enable --now sshd
```

**If the service is masked:**

```bash
sudo systemctl unmask sshd
sudo systemctl enable --now sshd
```

### 1.2 Verify the Daemon Is Listening on Port 22

```bash
sudo ss -tlnp | grep ':22 '
```

**Expected output:**

```
LISTEN  0  128  0.0.0.0:22  0.0.0.0:*  users:(("sshd",pid=1235,fd=3))
LISTEN  0  128     [::]:22     [::]:*  users:(("sshd",pid=1235,fd=4))
```

If the output is empty, SSH is not listening. Check the config:

```bash
sudo grep -i '^Port' /etc/ssh/sshd_config
```

If it shows `Port 2222` or another number, either change it back to `22` and
restart, or connect on that port instead.

### 1.3 Check and Open Firewall Port 22

#### UFW (Ubuntu/Debian)

```bash
sudo ufw status
```

**Expected output (port open):**

```
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
22/tcp (v6)                ALLOW       Anywhere (v6)
```

**If port 22 is missing:**

```bash
sudo ufw allow 22/tcp
sudo ufw reload
```

#### iptables (any Linux)

```bash
sudo iptables -L INPUT -n --line-numbers | grep ':22'
```

**Expected output:**

```
ACCEPT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:22
```

**If missing:**

```bash
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

#### Cloud Security Groups (AWS / GCP / Azure)

If the server runs in a cloud environment, verify the security group or
firewall rule allows inbound TCP 22 from your client IP (or `0.0.0.0/0`
for unrestricted access):

- **AWS:** EC2 → Security Groups → Inbound rules → Add rule → SSH (22)
- **GCP:** VPC → Firewall rules → Create rule → TCP:22, target tags
- **Azure:** NSG → Inbound security rules → Add → Destination port 22

### 1.4 Create or Reset the Test User

#### Create the user (first time)

```bash
sudo useradd -m -s /bin/bash testclientssh
echo 'testclientssh:pass123' | sudo chpasswd
```

**Expected output:** none (silent success).

#### Handle "user already exists" error

Running `useradd` when the user exists returns:

```
useradd: user 'testclientssh' already exists
```

**Detect and handle:**

```bash
if id testclientssh &>/dev/null; then
    echo "User exists — resetting password only."
    echo 'testclientssh:pass123' | sudo chpasswd
else
    echo "Creating user..."
    sudo useradd -m -s /bin/bash testclientssh
    echo 'testclientssh:pass123' | sudo chpasswd
fi
```

#### Lock / unlock the account

```bash
# Lock (disable login)
sudo passwd -l testclientssh

# Unlock (re-enable login)
sudo passwd -u testclientssh
```

#### Verify the account is active

```bash
sudo passwd -S testclientssh
```

**Expected output (active):**

```
testclientssh PS 2026-04-01 0 99999 7 -1 (Password set, SHA512 crypt.)
```

If the second field is `LK` instead of `PS`, the account is locked.

### 1.5 Verify SSH Configuration

```bash
sudo sshd -T | grep -iE 'port |passwordauth|permitroot|maxauth'
```

**Expected output:**

```
port 22
passwordauthentication yes
permitrootlogin prohibit-password
maxauthtries 6
```

**If `passwordauthentication` is `no`,** edit the config:

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## 2. Client Setup — Linux

### 2.1 Install OpenSSH Client

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install -y openssh-client

# Fedora / RHEL
sudo dnf install -y openssh-clients

# Arch
sudo pacman -S openssh
```

**Verify installation:**

```bash
ssh -V
```

**Expected output:**

```
OpenSSH_9.6p1, OpenSSL 3.1.4
```

### 2.2 Test Basic Connectivity

```bash
ssh -v testclientssh@152.53.155.143
```

The `-v` flag enables verbose output. On success you will see:

```
debug1: Connecting to 152.53.155.143 [152.53.155.143] port 22.
debug1: Connection established.
...
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: password
testclientssh@152.53.155.143's password:          ← type pass123
...
Welcome to Ubuntu 24.04 LTS (GNU/Linux 6.5.0-26-generic x86_64)
testclientssh@hostname:~$
```

### 2.3 Save the Host Key (optional)

To avoid the "authenticity can't be established" prompt on every connect:

```bash
ssh-keyscan -H 152.53.155.143 >> ~/.ssh/known_hosts
```

---

## 3. Client Setup — Windows

### 3.1 Option A — Built-in OpenSSH (Windows 10 1809+)

Open **PowerShell** as Administrator:

```powershell
# Verify the client is installed
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Client*'

# If not installed:
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

**Verify:**

```powershell
ssh -V
```

**Connect:**

```powershell
ssh testclientssh@152.53.155.143
```

### 3.2 Option B — PuTTY

1. Download from [putty.org](https://www.putty.org/) and install.
2. Open PuTTY.
3. In **Host Name** enter `152.53.155.143`, Port `22`, Connection type `SSH`.
4. Click **Open**.
5. When the terminal prompts `login as:`, type `testclientssh`.
6. When prompted for password, type `pass123`.

**Expected output after login:**

```
Welcome to Ubuntu 24.04 LTS (GNU/Linux 6.5.0-26-generic x86_64)
testclientssh@hostname:~$
```

### 3.3 Diagnose from Windows

```powershell
# Test TCP reachability
Test-NetConnection -ComputerName 152.53.155.143 -Port 22
```

**Expected output (port open):**

```
ComputerName     : 152.53.155.143
RemotePort       : 22
TcpTestSucceeded : True
```

**If `TcpTestSucceeded: False`**, the port is blocked. Check your local
firewall or the server's firewall.

```powershell
# Verbose SSH connection
ssh -v testclientssh@152.53.155.143
```

---

## 4. Client Setup — Android

### 4.1 Option A — Termux (Recommended)

1. Install **Termux** from F-Droid (not Play Store — the Play Store version
   is deprecated).

2. Open Termux and install the SSH client:

```bash
pkg update && pkg install -y openssh
```

3. Connect:

```bash
ssh -v testclientssh@152.53.155.143
```

4. Enter the password `pass123` when prompted.

**Expected output:**

```
Welcome to Ubuntu 24.04 LTS (GNU/Linux 6.5.0-26-generic x86_64)
testclientssh@hostname:~$
```

### 4.2 Option B — JuiceSSH or Termius (GUI Apps)

1. Install **JuiceSSH** or **Termius** from the Google Play Store.
2. Create a new connection:
   - **Address:** `152.53.155.143`
   - **Port:** `22`
   - **Username:** `testclientssh`
   - **Password:** `pass123`
3. Tap **Connect**.

### 4.3 Diagnose from Termux

```bash
# Test TCP reachability
nc -zv 152.53.155.143 22
```

**Expected output:**

```
Connection to 152.53.155.143 22 port [tcp/ssh] succeeded!
```

**If it fails:**

```
nc: 152.53.155.143 (152.53.155.143:22): Connection timed out
```

This indicates the port is blocked by a firewall or the server is down.

---

## 5. Connection Testing

### 5.1 Pre-Flight Checks (from any client)

```bash
# 1. DNS / IP resolution
ping -c 3 152.53.155.143

# 2. TCP port reachability
# Linux / macOS / Termux:
nc -zv 152.53.155.143 22
# Windows PowerShell:
Test-NetConnection 152.53.155.143 -Port 22

# 3. SSH banner grab
echo "" | nc 152.53.155.143 22
```

**Expected output from banner grab:**

```
SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu0.6
```

If you see this banner, the SSH daemon is listening and reachable.

### 5.2 Full SSH Connection Test

```bash
ssh -vvv testclientssh@152.53.155.143
```

`-vvv` enables maximum verbosity. Key lines to look for:

**Success indicators:**

```
debug1: Connecting to 152.53.155.143 [152.53.155.143] port 22.
debug1: Connection established.
debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6p1
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: password
testclientssh@152.53.155.143's password:
debug1: Authentication succeeded (password).
```

**Failure indicators:**

| Error | Meaning |
|-------|---------|
| `Connection timed out` | Port 22 blocked or server unreachable |
| `Connection refused` | SSH daemon not running |
| `Permission denied (publickey,password)` | Wrong password or auth disabled |
| `Permission denied (publickey)` | Password auth disabled on server |
| `Host key verification failed` | Server key changed (possible MITM) |

### 5.3 Verify Login Works

After connecting:

```bash
# Verify you are the correct user
whoami
# Expected: testclientssh

# Verify home directory
pwd
# Expected: /home/testclientssh

# Verify shell
echo $SHELL
# Expected: /bin/bash

# Exit
exit
```

### 5.4 Retrieve the Server's Host Key

```bash
ssh-keyscan 152.53.155.143 2>/dev/null
```

**Expected output:**

```
152.53.155.143 ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB...
152.53.155.143 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHA...
152.53.155.143 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
```

Save to known_hosts to skip the fingerprint prompt:

```bash
ssh-keyscan 152.53.155.143 >> ~/.ssh/known_hosts
```

---

## 6. Troubleshooting Common Issues

### 6.1 Connection Timeout

**Symptom:** `ssh: connect to host 152.53.155.143 port 22: Connection timed out`

**Diagnosis:**

```bash
# From client — is the server reachable at all?
ping -c 3 152.53.155.143

# Is the port open?
nc -zv 152.53.155.143 22
```

**Fix (on server):**

```bash
# Open firewall port
sudo ufw allow 22/tcp
sudo ufw reload

# Verify
sudo ufw status | grep 22
```

If running in a cloud VM, also check the security group (see §1.3).

### 6.2 Connection Refused

**Symptom:** `ssh: connect to host 152.53.155.143 port 22: Connection refused`

**Diagnosis (on server):**

```bash
sudo systemctl status sshd
sudo ss -tlnp | grep ':22 '
```

**Fix:**

```bash
sudo systemctl enable --now sshd
```

### 6.3 Permission Denied (password)

**Symptom:** `testclientssh@152.53.155.143: Permission denied (publickey,password).`

**Diagnosis (on server):**

```bash
# Is password auth enabled?
sudo sshd -T | grep passwordauthentication
# Expected: passwordauthentication yes

# Is the account locked?
sudo passwd -S testclientssh
# Second field should be PS, not LK
```

**Fix:**

```bash
# Enable password authentication
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config
sudo systemctl restart sshd

# Unlock the account
sudo passwd -u testclientssh

# Reset password
echo 'testclientssh:pass123' | sudo chpasswd
```

### 6.4 Permission Denied (publickey only)

**Symptom:** `testclientssh@152.53.155.143: Permission denied (publickey).`

This means password authentication is disabled on the server.

**Fix:**

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config
sudo sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' \
    /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### 6.5 Host Key Verification Failed

**Symptom:** `@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @`

This means the server's host key has changed since the last connection.

**Fix:**

```bash
# Remove the old key
ssh-keygen -R 152.53.155.143

# Reconnect — you will be prompted to accept the new key
ssh testclientssh@152.53.155.143
```

### 6.6 Wrong File Permissions on the Server

SSH refuses to start if critical files have incorrect permissions.

**Diagnosis:**

```bash
ls -la /etc/ssh/sshd_config
ls -la /etc/ssh/ssh_host_*_key
```

**Expected permissions:**

| File | Owner | Mode |
|------|-------|------|
| `/etc/ssh/sshd_config` | `root:root` | `600` |
| `/etc/ssh/ssh_host_*_key` | `root:root` | `600` |
| `/etc/ssh/ssh_host_*_key.pub` | `root:root` | `644` |

**Fix:**

```bash
sudo chown root:root /etc/ssh/sshd_config
sudo chmod 600 /etc/ssh/sshd_config

sudo chown root:root /etc/ssh/ssh_host_*_key
sudo chmod 600 /etc/ssh/ssh_host_*_key

sudo chown root:root /etc/ssh/ssh_host_*_key.pub
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub

sudo systemctl restart sshd
```

### 6.7 SELinux Restrictions (RHEL / CentOS / Fedora)

**Diagnosis:**

```bash
sudo ausearch -m avc -ts recent | grep sshd
sudo sealert -a /var/log/audit/audit.log | grep sshd
```

**Fix:**

```bash
# If SSH runs on a non-standard port, update the SELinux policy
sudo semanage port -a -t ssh_port_t -p tcp 22

# Relabel SSH files if needed
sudo restorecon -Rv /etc/ssh/

# Restart SSH
sudo systemctl restart sshd
```

### 6.8 AppArmor Restrictions (Ubuntu / Debian)

**Diagnosis:**

```bash
sudo aa-status | grep sshd
sudo journalctl -xe | grep apparmor | grep sshd
```

**Fix:**

```bash
# Put the SSH profile in complain mode (logs violations without blocking)
sudo aa-complain /usr/sbin/sshd

# Or disable entirely (not recommended for production)
sudo aa-disable /usr/sbin/sshd

sudo systemctl restart sshd
```

### 6.9 Too Many Authentication Failures

**Symptom:** `Received disconnect from 152.53.155.143 port 22:2: Too many authentication failures`

This happens when the client sends too many keys before the password prompt.

**Fix (client side):**

```bash
ssh -o PubkeyAuthentication=no testclientssh@152.53.155.143
```

Or add to `~/.ssh/config`:

```
Host 152.53.155.143
    PubkeyAuthentication no
    PasswordAuthentication yes
```

---

## 7. Auto-Fix Scripts

### 7.1 Server-Side Full Fix Script

Save as `fix_ssh.sh` and run with `sudo bash fix_ssh.sh` on the server:

```bash
#!/usr/bin/env bash
# fix_ssh.sh — Restores SSH to a known-good state
set -euo pipefail

echo "=== SSH Auto-Fix ==="

# 1. Ensure sshd is installed
if ! command -v sshd &>/dev/null; then
    echo "Installing OpenSSH server..."
    apt-get update -qq && apt-get install -y openssh-server
fi

# 2. Ensure password authentication is enabled
echo "Configuring sshd_config..."
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
    /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' \
    /etc/ssh/sshd_config

# 3. Fix file permissions
echo "Fixing permissions..."
chown root:root /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config
for keyfile in /etc/ssh/ssh_host_*_key; do
    chown root:root "$keyfile"
    chmod 600 "$keyfile"
done
for pubfile in /etc/ssh/ssh_host_*_key.pub; do
    chown root:root "$pubfile"
    chmod 644 "$pubfile"
done

# 4. Open firewall port
if command -v ufw &>/dev/null; then
    echo "Opening port 22 via UFW..."
    ufw allow 22/tcp
    ufw reload
elif command -v iptables &>/dev/null; then
    echo "Opening port 22 via iptables..."
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
fi

# 5. Create or reset test user
echo "Configuring test user..."
if id testclientssh &>/dev/null; then
    echo "  User exists — resetting password."
else
    useradd -m -s /bin/bash testclientssh
    echo "  User created."
fi
echo 'testclientssh:pass123' | chpasswd
passwd -u testclientssh 2>/dev/null || true

# 6. Restart SSH daemon
echo "Restarting sshd..."
sshd -t && {
    systemctl restart sshd
    systemctl enable sshd
    echo "SSH is running."
} || {
    echo "ERROR: sshd_config has syntax errors:"
    sshd -t
    exit 1
}

# 7. Verify
echo ""
echo "=== Verification ==="
systemctl is-active sshd
ss -tlnp | grep ':22 '
echo "Done."
```

### 7.2 Quick One-Liners

```bash
# Open port 22 and restart SSH (UFW)
sudo ufw allow 22/tcp && sudo systemctl restart sshd

# Reset the test user's password
echo 'testclientssh:pass123' | sudo chpasswd

# Fix sshd_config permissions
sudo chown root:root /etc/ssh/sshd_config && sudo chmod 600 /etc/ssh/sshd_config

# Regenerate host keys (if corrupted)
sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server && sudo systemctl restart sshd

# Allow SSH through SELinux
sudo semanage port -a -t ssh_port_t -p tcp 22

# Disable AppArmor for SSH (temporary)
sudo aa-complain /usr/sbin/sshd && sudo systemctl restart sshd

# Verify SSH is healthy (all-in-one)
sudo sshd -t && sudo systemctl status sshd --no-pager && sudo ss -tlnp | grep ':22 '
```

### 7.3 Client-Side Diagnostic Script

Save as `test_ssh.sh` and run from any Linux client:

```bash
#!/usr/bin/env bash
# test_ssh.sh — Tests SSH connectivity to the target server
SERVER="152.53.155.143"
USER="testclientssh"
PORT=22

echo "=== Testing SSH connectivity to $SERVER ==="

echo -n "1. Ping: "
ping -c 1 -W 3 "$SERVER" &>/dev/null && echo "OK" || echo "FAIL"

echo -n "2. TCP port $PORT: "
nc -zv -w 3 "$SERVER" "$PORT" &>/dev/null && echo "OPEN" || echo "CLOSED/TIMEOUT"

echo -n "3. SSH banner: "
BANNER=$(echo "" | nc -w 3 "$SERVER" "$PORT" 2>/dev/null | head -1)
if [[ "$BANNER" == SSH-* ]]; then
    echo "$BANNER"
else
    echo "NO RESPONSE"
fi

echo "4. SSH connection test (verbose):"
ssh -o ConnectTimeout=10 -o BatchMode=yes "${USER}@${SERVER}" exit 2>&1 | head -5

echo ""
echo "If BatchMode fails with 'Permission denied', password auth is working"
echo "(it just means you need an interactive prompt)."
echo ""
echo "Full interactive test:"
echo "  ssh ${USER}@${SERVER}"
echo "  password: pass123"
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Check SSH daemon status | `sudo systemctl status sshd` |
| Restart SSH daemon | `sudo systemctl restart sshd` |
| Open port 22 (UFW) | `sudo ufw allow 22/tcp` |
| Open port 22 (iptables) | `sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT` |
| Check listening ports | `sudo ss -tlnp \| grep ':22 '` |
| Create user | `sudo useradd -m -s /bin/bash testclientssh` |
| Set password | `echo 'testclientssh:pass123' \| sudo chpasswd` |
| Reset existing password | `echo 'testclientssh:pass123' \| sudo chpasswd` |
| Unlock account | `sudo passwd -u testclientssh` |
| Enable password auth | Set `PasswordAuthentication yes` in `/etc/ssh/sshd_config` |
| Fix config permissions | `sudo chmod 600 /etc/ssh/sshd_config` |
| Test connection (verbose) | `ssh -vvv testclientssh@152.53.155.143` |
| Test TCP reachability | `nc -zv 152.53.155.143 22` |
| Grab SSH banner | `echo "" \| nc 152.53.155.143 22` |
| Remove stale host key | `ssh-keygen -R 152.53.155.143` |
| Windows TCP test | `Test-NetConnection 152.53.155.143 -Port 22` |
