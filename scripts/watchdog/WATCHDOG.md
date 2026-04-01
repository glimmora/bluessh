# Build Watchdog — Configuration Guide

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     File System Events                        │
│                                                              │
│  build_ubuntu.sh ──modified──▶ inotifywait (Linux)           │
│  build_windows.bat ─modified─▶ FileSystemWatcher (Windows)   │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                      Watchdog Core                            │
│                                                              │
│  1. Execute build script                                     │
│  2. Capture stdout/stderr to log file                        │
│  3. Exit code == 0? → SUCCEED (notify, wait for next)       │
│  4. Exit code != 0? → ANALYZE                                │
│     ├─ Match log against error patterns                      │
│     ├─ For each match: call fix function                     │
│     └─ RETRY (up to MAX_RETRIES)                             │
│  5. Final failure → NOTIFY with log path                     │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  Error Patterns Database                                     │
│                                                              │
│  Linux:  patterns/*.patterns      (regex|desc|fix_func)     │
│  Windows: patterns/*.patterns.ps1 (PowerShell hashtable)     │
│                                                              │
│  20 built-in patterns for Linux                              │
│  14 built-in patterns for Windows                            │
└──────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
scripts/watchdog/
├── watch_ubuntu.sh          # Linux watchdog (Bash + inotify)
├── watch_windows.ps1        # Windows watchdog (PowerShell)
├── watchdog.conf            # Linux config
├── watchdog.conf.ps1        # Windows config
├── patterns/
│   ├── linux.patterns       # Linux error patterns
│   └── windows.patterns.ps1 # Windows error patterns
├── logs/                    # Auto-created
│   ├── watchdog_YYYYMMDD.log    # Execution log
│   ├── actions_YYYYMMDD.log     # Actions taken
│   └── build_*.log              # Per-build logs
└── WATCHDOG.md              # This file
```

## Quick Start

### Linux

```bash
# Install dependency
sudo apt-get install -y inotify-tools

# Run (interactive)
./scripts/watchdog/watch_ubuntu.sh

# Run (daemon, background)
./scripts/watchdog/watch_ubuntu.sh --daemon

# Stop daemon
kill $(cat scripts/watchdog/logs/watchdog.pid)
```

### Windows (PowerShell)

```powershell
# Run (interactive, requires Admin for auto-fixes)
.\scripts\watchdog\watch_windows.ps1

# Run (background job)
.\scripts\watchdog\watch_windows.ps1 -Daemon

# Run without notifications
.\scripts\watchdog\watch_windows.ps1 -NoNotify
```

## Configuration

### Linux (`watchdog.conf`)

```bash
# File to monitor
WATCHED_FILE="/home/blue/projects/BlueSSH/scripts/build_ubuntu.sh"

# Max retry attempts (default: 3)
MAX_RETRIES=3

# Seconds between retries (default: 5)
RETRY_DELAY=5

# Cooldown after file change in seconds (default: 3)
COOLDOWN_SECONDS=3

# Email notification (requires mailutils)
NOTIFY_EMAIL="dev@example.com"

# Desktop notifications via notify-send
NOTIFY_DESKTOP=true

# Auto-delete logs older than N days
LOG_RETENTION_DAYS=30
```

### Windows (`watchdog.conf.ps1`)

```powershell
$WatchedFile = "C:\Projects\BlueSSH\scripts\build_windows.bat"
$MaxRetries = 3
$RetryDelay = 5
$CooldownSeconds = 3
$NotifyDesktop = $true
$LogRetentionDays = 30
```

## Error Pattern Format

### Linux (`patterns/*.patterns`)

Each line is: `regex|description|fix_function_name`

```bash
# Comment line
command not found|Missing command|fix_missing_command
Permission denied|Permission error|fix_permissions
E: Unable to locate package|Package not found|fix_update_repos
```

- **regex**: Perl-compatible regex matched against the build log
- **description**: Human-readable label shown in console and logs
- **fix_function_name**: Name of a bash function in `watch_ubuntu.sh`

### Windows (`patterns/*.patterns.ps1`)

Returns an array of hashtables:

```powershell
@(
    @{
        Pattern     = "'[^']+ is not recognized"
        Description = "Command not found"
        Fix         = { param($log) Fix-MissingCommand $log }
    }
)
```

## Adding New Error Patterns

### Step 1: Identify the error

Run the build manually and note the exact error message:

```
error: could not find `toml_edit` in registry `crates-io`
```

### Step 2: Write the pattern

**Linux** — add to `patterns/linux.patterns`:
```bash
could not find `.+` in registry|Crate not found in registry|fix_crate_not_found
```

**Windows** — add to `patterns/windows.patterns.ps1`:
```powershell
@{
    Pattern     = "could not find .+ in registry"
    Description = "Crate not found in registry"
    Fix         = { param($log) Fix-CrateNotFound $log }
}
```

### Step 3: Implement the fix function

**Linux** — add to `watch_ubuntu.sh`:
```bash
fix_crate_not_found() {
    local log_content="$1"
    log_fix "Updating Cargo registry..."
    cargo update 2>/dev/null && return 0
    return 1
}
```

**Windows** — add to `watch_windows.ps1`:
```powershell
function Fix-CrateNotFound {
    param($LogContent)
    Write-Log "FIX" "Updating Cargo registry..."
    Write-Action "cargo update"
    try { cargo update; return $true } catch { return $false }
}
```

## Built-in Fix Functions

### Linux (20 functions)

| Function | Trigger | Action |
|----------|---------|--------|
| `fix_missing_command` | `command not found` | Installs the missing package via apt |
| `fix_missing_path` | `No such file or directory` | Creates missing directories |
| `fix_permissions` | `Permission denied` | Runs `chmod +x` |
| `fix_update_repos` | `Unable to locate package` | Runs `apt-get update` |
| `fix_dpkg_lock` | `dpkg: error` | Runs `dpkg --configure -a` |
| `fix_apt_lock` | `Could not get lock` | Waits for lock, force-releases after 60s |
| `fix_disk_space` | `No space left` | Cleans apt cache, old logs, snap revisions |
| `fix_not_git_repo` | `not a git repository` | Runs `git init` |
| `fix_install_build_tools` | `linker not found` | Installs `build-essential` |
| `fix_install_pkgconfig` | `pkg-config not found` | Installs `pkg-config` |
| `fix_install_cmake` | `cmake not found` | Installs `cmake` |
| `fix_broken_deps` | `unmet dependencies` | Runs `apt-get install -f` |
| `fix_python_deps` | `ImportError` | Installs missing Python module |
| `fix_python_module` | `ModuleNotFoundError` | Installs missing Python module |
| `fix_npm_error` | `npm ERR!` | Clears npm cache, reinstalls |
| `fix_install_rust` | `cargo not found` | Installs Rust via rustup |
| `fix_install_java` | `javac not found` | Installs `default-jdk` |
| `fix_linker_error` | `undefined reference to` | Installs the missing `-l` library |
| `fix_mkdir` | `cannot create directory` | Creates parent directory |

### Windows (14 functions)

| Function | Trigger | Action |
|----------|---------|--------|
| `Fix-MissingCommand` | `not recognized` | Installs via winget |
| `Fix-MissingPath` | `cannot find the file` | Creates missing directories |
| `Fix-Permission` | `Access is denied` | Recommends elevation |
| `Fix-MSBuild` | `error MSB` | Installs VS Build Tools |
| `Fix-Linker` | `error LNK` | Installs MSVC tools |
| `Fix-CompilerFatal` | `fatal error C` | Checks memory, recommends VS repair |
| `Fix-RustCompile` | `could not compile` | Checks for linker/crate issues |
| `Fix-InstallRust` | `cargo not recognized` | Downloads and runs rustup-init |
| `Fix-NuGet` | `nuget Unable to resolve` | Clears NuGet cache |
| `Fix-DiskSpace` | `not enough space` | Cleans temp, Windows Update cache |
| `Fix-FileLock` | `used by another process` | Waits 10s |
| `Fix-MSVCTools` | `linker not found` | Installs VS Build Tools |
| `Fix-NpmError` | `npm ERR!` | Clears npm cache, reinstalls |
| `Fix-WindowsSDK` | `Windows SDK not found` | Installs via VS Installer |
| `Fix-RustBuildScript` | `failed to run custom build` | Installs missing deps |

## Extending Auto-Fix Logic

### Adding a new platform

1. Create `watch_<platform>.sh` or `.ps1`
2. Implement the same flow: `watch → execute → analyze → fix → retry`
3. Create `patterns/<platform>.patterns`
4. Register fix functions

### Adding a custom fix chain

A fix can trigger other fixes. For example, a linker error might be caused
by missing build tools, which itself might need the package repos updated.

In the bash script, call other fix functions from within a fix:

```bash
fix_linker_error() {
    local log_content="$1"
    # First ensure repos are current
    fix_update_repos "$log_content" || true
    # Then try to install the library
    # ...
}
```

## Log Files

| File | Contents |
|------|----------|
| `watchdog_YYYYMMDD.log` | All watchdog activity with timestamps |
| `actions_YYYYMMDD.log` | Only actions taken (fixes, builds, notifications) |
| `build_YYYYMMDD_HHMMSS_attemptN.log` | Full build output per attempt |
| `build_*.log.exitcode` | Exit code for each build attempt |
| `watchdog.pid` | Daemon PID (Linux only) |

## Troubleshooting

### "inotifywait: command not found"
```bash
sudo apt-get install inotify-tools
```

### "Permission denied" on auto-fix functions
Run the watchdog with sudo or add your user to the relevant groups:
```bash
sudo usermod -aG sudo $USER
```

### Watchdog not detecting changes
- Some editors use atomic writes (save to temp, rename). inotify detects `move_to` events but not always `modify`.
- The watchdog watches `modify`, `move_to`, and `create` events.
- If issues persist, reduce `COOLDOWN_SECONDS` to 1.

### Too many false positives in error patterns
Make patterns more specific by anchoring to context:
```bash
# Instead of:
command not found|Missing command|fix_missing_command

# Use:
\S+: command not found|Specific missing command|fix_missing_command
```

### Email notifications not sending
```bash
sudo apt-get install mailutils
echo "test" | mail -s "test" you@example.com
```
