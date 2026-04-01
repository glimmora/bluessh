#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  vps_fix_all.sh — Run on VPS 152.53.155.143
#
#  Creates user tester1, enables SSH password auth, installs VNC,
#  configures RDP, and opens all required firewall ports.
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "═══════════════════════════════════════════════════════════"
echo "  BlueSSH VPS Auto-Fix"
echo "  Server: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "═══════════════════════════════════════════════════════════"

# ─── 1. Create/fix user tester1 ─────────────────────────────────────
echo ""
echo "━━━ Step 1: User Account ━━━"

USERNAME="tester1"
PASSWORD="Z9IQv3RczcPw"

if id "$USERNAME" &>/dev/null; then
    ok "User '$USERNAME' exists (uid=$(id -u "$USERNAME")). Resetting password."
else
    sudo useradd -m -s /bin/bash "$USERNAME"
    ok "Created user '$USERNAME'"
fi

echo "$USERNAME:$PASSWORD" | sudo chpasswd
ok "Password set for '$USERNAME'"

# Verify
sudo id "$USERNAME"
sudo getent passwd "$USERNAME"

# ─── 2. Fix SSH config ──────────────────────────────────────────────
echo ""
echo "━━━ Step 2: SSH Configuration ━━━"

SSHD_CONFIG="/etc/ssh/sshd_config"
sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)" 2>/dev/null || true

# Enable password authentication
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
sudo sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' "$SSHD_CONFIG"
sudo sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' "$SSHD_CONFIG"
sudo sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONFIG"

# Ensure tester1 is NOT in DenyUsers
sudo sed -i "/^DenyUsers.*$USERNAME/d" "$SSHD_CONFIG"

# Ensure AllowUsers includes tester1 (or is not restrictive)
if grep -q "^AllowUsers" "$SSHD_CONFIG"; then
    if ! grep -q "AllowUsers.*$USERNAME" "$SSHD_CONFIG"; then
        sudo sed -i "s/^AllowUsers.*/& $USERNAME/" "$SSHD_CONFIG"
    fi
fi

# Enable root login for initial setup (optional, comment out for production)
# sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"

sudo sshd -t 2>&1 && ok "sshd_config syntax valid" || fail "sshd_config has errors"

sudo systemctl restart sshd || sudo systemctl restart ssh
ok "SSH daemon restarted"

# ─── 3. Open firewall ports ─────────────────────────────────────────
echo ""
echo "━━━ Step 3: Firewall ━━━"

if command -v ufw &>/dev/null; then
    sudo ufw allow 22/tcp
    sudo ufw allow 3389/tcp
    sudo ufw allow 5901/tcp
    sudo ufw allow 80/tcp
    sudo ufw --force enable
    ok "UFW rules applied: 22, 80, 3389, 5901"
    sudo ufw status verbose
else
    sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 3389 -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 5901 -j ACCEPT
    ok "iptables rules added"
fi

# ─── 4. Install VNC Server ──────────────────────────────────────────
echo ""
echo "━━━ Step 4: VNC Server ━━━"

if command -v vncserver &>/dev/null; then
    ok "VNC server already installed"
else
    echo "Installing TigerVNC..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq tigervnc-standalone-server tigervnc-common dbus-x11
    ok "VNC server installed"
fi

# Set VNC password
VNC_DIR="/home/$USERNAME/.vnc"
sudo -u "$USERNAME" mkdir -p "$VNC_DIR"
echo "$PASSWORD" | sudo -u "$USERNAME" vncpasswd -f > "$VNC_DIR/passwd"
sudo chmod 600 "$VNC_DIR/passwd"
ok "VNC password set"

# Create xstartup
sudo tee "$VNC_DIR/xstartup" > /dev/null << 'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/tmp/runtime-$(id -u)
mkdir -p $XDG_RUNTIME_DIR
chmod 700 $XDG_RUNTIME_DIR

# Start XFCE4 if available, otherwise basic xterm
if command -v startxfce4 &>/dev/null; then
    exec startxfce4
elif command -v gnome-session &>/dev/null; then
    exec gnome-session
else
    exec xterm -geometry 80x24+10+10 -ls
fi
XEOF
sudo chmod +x "$VNC_DIR/xstartup"
sudo chown -R "$USERNAME:$USERNAME" "$VNC_DIR"
ok "VNC xstartup configured"

# Kill any existing VNC sessions
sudo -u "$USERNAME" vncserver -kill :1 2>/dev/null || true
sleep 1

# Start VNC on display :1 (port 5901)
sudo -u "$USERNAME" vncserver :1 -geometry 1920x1080 -depth 24 -localhost no &
sleep 3

if ss -tlnp | grep -q ':5901'; then
    ok "VNC server running on port 5901"
else
    warn "VNC may not be running. Trying alternative start..."
    sudo -u "$USERNAME" vncserver :1 -geometry 1920x1080 -depth 24 2>&1 || true
    sleep 2
    ss -tlnp | grep -q ':5901' && ok "VNC running" || fail "VNC failed to start"
fi

# ─── 5. Verify RDP ──────────────────────────────────────────────────
echo ""
echo "━━━ Step 5: RDP Server ━━━"

if systemctl is-active --quiet xrdp 2>/dev/null; then
    ok "xrdp is running"
else
    if ! command -v xrdp &>/dev/null; then
        echo "Installing xrdp..."
        sudo apt-get install -y -qq xrdp xfce4 xfce4-goodies
    fi
    sudo systemctl enable --now xrdp
    ok "xrdp started"
fi

# Configure xrdp to use XFCE
echo "xfce4-session" | sudo -u "$USERNAME" tee /home/"$USERNAME"/.xsession > /dev/null
sudo chown "$USERNAME:$USERNAME" /home/"$USERNAME"/.xsession

# Add tester1 to ssl-cert group (required for xrdp)
sudo usermod -aG ssl-cert "$USERNAME" 2>/dev/null || true

sudo systemctl restart xrdp 2>/dev/null || true
ss -tlnp | grep -q ':3389' && ok "RDP listening on port 3389" || warn "RDP not on 3389"

# ─── 6. Verify all services ─────────────────────────────────────────
echo ""
echo "━━━ Step 6: Verification ━━━"

echo "Port status:"
for port in 22 80 3389 5901; do
    if ss -tlnp | grep -q ":${port} "; then
        echo "  Port $port: OPEN"
    else
        echo "  Port $port: CLOSED"
    fi
done

echo ""
echo "Service status:"
systemctl is-active sshd 2>/dev/null && echo "  sshd: ACTIVE" || echo "  sshd: INACTIVE"
systemctl is-active xrdp 2>/dev/null && echo "  xrdp: ACTIVE" || echo "  xrdp: INACTIVE"
ss -tlnp | grep -q ':5901' && echo "  vnc: ACTIVE" || echo "  vnc: INACTIVE"

echo ""
echo "User verification:"
id "$USERNAME"
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "  VPS Fix Complete!"
echo ""
echo "  SSH:  ssh $USERNAME@152.53.155.143"
echo "  VNC:  connect to 152.53.155.143:5901"
echo "  RDP:  connect to 152.53.155.143:3389"
echo "═══════════════════════════════════════════════════════════"
