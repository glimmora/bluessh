# ══════════════════════════════════════════════════════════════════════
#  watchdog.conf.ps1 — Configuration for the Windows build watchdog
# ══════════════════════════════════════════════════════════════════════

# File to watch
$WatchedFile = "C:\Projects\BlueSSH\scripts\build_windows.bat"

# Max auto-fix retry attempts
$MaxRetries = 3

# Seconds to wait between retries
$RetryDelay = 5

# Cooldown after file change before triggering build
$CooldownSeconds = 3

# Desktop toast notifications
$NotifyDesktop = $true

# Auto-delete logs older than N days
$LogRetentionDays = 30
