# ══════════════════════════════════════════════════════════════════════
#  watch_windows.ps1 — Build Watchdog for Windows
#
#  Monitors build_windows.bat via FileSystemWatcher, executes it,
#  captures output, detects errors, applies fixes, and re-runs.
#
#  Usage:
#    .\watch_windows.ps1 [-Config <path>] [-Daemon] [-NoNotify]
#
#  Requirements:
#    - PowerShell 5.1+ (ships with Windows 10+)
#    - Run in elevated PowerShell for package auto-fixes
# ══════════════════════════════════════════════════════════════════════

[CmdletBinding()]
param(
    [string]$Config = "",
    [switch]$Daemon,
    [switch]$NoNotify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Configuration ────────────────────────────────────────────────────
$WatchdogDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogDir = Join-Path $WatchdogDir "logs"
$PatternDir = Join-Path $WatchdogDir "patterns"

# Defaults
$WatchedFile = "C:\Projects\BlueSSH\scripts\build_windows.bat"
$MaxRetries = 3
$RetryDelay = 5
$NotifyDesktop = -not $NoNotify
$LogRetentionDays = 30
$CooldownSeconds = 3

# Load config if present
$ConfigFile = if ($Config) { $Config } else { Join-Path $WatchdogDir "watchdog.conf.ps1" }
if (Test-Path $ConfigFile) {
    . $ConfigFile
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ─── Logging ──────────────────────────────────────────────────────────
function Get-Timestamp { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Timestamp
    $colors = @{
        "INFO" = "Cyan"; "OK" = "Green"; "WARN" = "Yellow";
        "ERR" = "Red"; "FIX" = "Magenta"; "ACT" = "DarkCyan"
    }
    $c = if ($colors.ContainsKey($Level)) { $colors[$Level] } else { "White" }
    Write-Host "$ts [$Level]  " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor $c

    $logFile = Join-Path $LogDir "watchdog_$(Get-Date -Format 'yyyyMMdd').log"
    "$ts [$Level] $Message" | Out-File -Append -FilePath $logFile -Encoding UTF8
}

function Write-Action {
    param([string]$Message)
    Write-Log "ACT" $Message
    $actionLog = Join-Path $LogDir "actions_$(Get-Date -Format 'yyyyMMdd').log"
    "$(Get-Timestamp) [ACTION] $Message" | Out-File -Append -FilePath $actionLog -Encoding UTF8
}

# ─── Error Pattern Database ──────────────────────────────────────────
$ErrorPatterns = @()

function Load-Patterns {
    # Load from pattern files
    $patternFiles = Get-ChildItem -Path $PatternDir -Filter "*.patterns.ps1" -ErrorAction SilentlyContinue
    foreach ($pf in $patternFiles) {
        Write-Log "INFO" "Loading patterns from $($pf.Name)"
        $script:ErrorPatterns += & $pf.FullName
    }

    # Built-in Windows patterns
    $script:ErrorPatterns += @(
        @{
            Pattern     = "'[^']+ is not recognized"
            Description = "Command not found"
            Fix         = { param($log) Fix-MissingCommand $log }
        },
        @{
            Pattern     = "The system cannot find the (file|path) specified"
            Description = "Missing file or path"
            Fix         = { param($log) Fix-MissingPath $log }
        },
        @{
            Pattern     = "Access is denied"
            Description = "Permission denied"
            Fix         = { param($log) Fix-Permission $log }
        },
        @{
            Pattern     = "The system cannot find the drive specified"
            Description = "Drive not available"
            Fix         = { param($log) Fix-DriveNotFound $log }
        },
        @{
            Pattern     = "MSBuild.*error MSB"
            Description = "MSBuild error"
            Fix         = { param($log) Fix-MSBuild $log }
        },
        @{
            Pattern     = "error LNK\d+"
            Description = "Linker error"
            Fix         = { param($log) Fix-Linker $log }
        },
        @{
            Pattern     = "fatal error C\d+"
            Description = "C/C++ compiler fatal error"
            Fix         = { param($log) Fix-CompilerFatal $log }
        },
        @{
            Pattern     = "error: could not compile"
            Description = "Rust compilation error"
            Fix         = { param($log) Fix-RustCompile $log }
        },
        @{
            Pattern     = "cargo: command not found|cargo is not recognized"
            Description = "Cargo/Rust not installed"
            Fix         = { param($log) Fix-InstallRust $log }
        },
        @{
            Pattern     = "nuget.*Unable to resolve"
            Description = "NuGet dependency resolution failure"
            Fix         = { param($log) Fix-NuGet $log }
        },
        @{
            Pattern     = "There is not enough space on the disk"
            Description = "Disk full"
            Fix         = { param($log) Fix-DiskSpace $log }
        },
        @{
            Pattern     = "The process cannot access the file because it is being used by another process"
            Description = "File locked"
            Fix         = { param($log) Fix-FileLock $log }
        },
        @{
            Pattern     = "error: linker `?link\.exe`? not found"
            Description = "MSVC linker not found"
            Fix         = { param($log) Fix-MSVCTools $log }
        },
        @{
            Pattern     = "node_modules.*error|npm ERR!"
            Description = "npm error"
            Fix         = { param($log) Fix-NpmError $log }
        },
        @{
            Pattern     = "The Windows SDK .* was not found"
            Description = "Windows SDK missing"
            Fix         = { param($log) Fix-WindowsSDK $log }
        },
        @{
            Pattern     = "error: failed to run custom build command"
            Description = "Rust build script failure"
            Fix         = { param($log) Fix-RustBuildScript $log }
        }
    )

    Write-Log "INFO" "Loaded $($script:ErrorPatterns.Count) error patterns"
}

# ─── Fix Functions ────────────────────────────────────────────────────
function Fix-MissingCommand {
    param($LogContent)
    $cmd = if ($LogContent -match "'([^']+)' is not recognized") { $Matches[1] } else { "" }
    if (-not $cmd) { return $false }

    Write-Log "FIX" "Missing command: $cmd"
    Write-Action "Attempting to install: $cmd"

    $pkgMap = @{
        "cargo"  = { Install-RustUp }
        "rustc"  = { Install-RustUp }
        "node"   = { winget install OpenJS.NodeJS.LTS -e --accept-package-agreements }
        "npm"    = { winget install OpenJS.NodeJS.LTS -e --accept-package-agreements }
        "cmake"  = { winget install Kitware.CMake -e --accept-package-agreements }
        "git"    = { winget install Git.Git -e --accept-package-agreements }
        "python" = { winget install Python.Python.3.12 -e --accept-package-agreements }
    }

    if ($pkgMap.ContainsKey($cmd)) {
        try { & $pkgMap[$cmd]; return $true } catch { return $false }
    }
    return $false
}

function Fix-MissingPath {
    param($LogContent)
    if ($LogContent -match "The system cannot find the (file|path) specified") {
        $lines = $LogContent -split "`n"
        foreach ($line in $lines) {
            if ($line -match "([^\\/:*?`"<>|]+\.[^\\/:*?`"<>|]+)") {
                $path = $Matches[1]
                $dir = Split-Path $path -Parent -ErrorAction SilentlyContinue
                if ($dir -and -not (Test-Path $dir)) {
                    Write-Log "FIX" "Creating directory: $dir"
                    Write-Action "mkdir $dir"
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    return $true
                }
            }
        }
    }
    return $false
}

function Fix-Permission {
    param($LogContent)
    Write-Log "FIX" "Permission issue detected. Try running as Administrator."
    Write-Action "Permission error — recommending elevated PowerShell"

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "WARN" "Not running as Administrator. Some fixes require elevation."
    }
    return $false
}

function Fix-DriveNotFound {
    param($LogContent)
    Write-Log "FIX" "Drive not available. Check drive mappings."
    Write-Action "Drive mapping issue detected"
    return $false
}

function Fix-MSBuild {
    param($LogContent)
    Write-Log "FIX" "MSBuild error detected. Checking VS installation..."
    Write-Action "Checking MSBuild/VS Build Tools"

    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $installPath = & $vsWhere -latest -property installationPath -requires Microsoft.VisualStudio.Workload.VCTools 2>$null
        if ($installPath) {
            Write-Log "OK" "VS Build Tools found at: $installPath"
            return $true
        }
    }

    Write-Log "FIX" "Installing VS Build Tools via winget..."
    try {
        winget install Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        return $true
    } catch { return $false }
}

function Fix-Linker {
    param($LogContent)
    Write-Log "FIX" "Linker error. Checking MSVC tools..."
    Write-Action "Fixing linker error"
    return (Fix-MSBuild $LogContent)
}

function Fix-CompilerFatal {
    param($LogContent)
    Write-Log "FIX" "Compiler fatal error. Likely out of memory or corrupted install."
    Write-Action "Compiler fatal error"

    # Check memory
    $mem = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($mem -lt 1) {
        Write-Log "WARN" "Low memory: ${mem}GB free. Close other applications."
    }
    return $false
}

function Fix-RustCompile {
    param($LogContent)
    Write-Log "FIX" "Rust compilation error. Checking toolchain..."
    Write-Action "Checking Rust toolchain"

    if ($LogContent -match "linker.*not found") {
        return (Fix-MSVCTools $LogContent)
    }
    if ($LogContent -match "could not find .* in (registry|crates)") {
        Write-Log "FIX" "Updating crate index..."
        cargo update 2>$null
        return $true
    }
    return $false
}

function Fix-InstallRust {
    param($LogContent)
    Write-Log "FIX" "Installing Rust via rustup-init..."
    Write-Action "Installing Rust"

    try {
        Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile "$env:TEMP\rustup-init.exe"
        & "$env:TEMP\rustup-init.exe" -y --default-toolchain stable
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        return (Get-Command cargo -ErrorAction SilentlyContinue) -ne $null
    } catch { return $false }
}

function Fix-NuGet {
    param($LogContent)
    Write-Log "FIX" "Clearing NuGet cache..."
    Write-Action "nuget locals all -clear"
    try { dotnet nuget locals all --clear; return $true } catch { return $false }
}

function Fix-DiskSpace {
    param($LogContent)
    Write-Log "FIX" "Disk space issue. Cleaning temp files..."
    Write-Action "Cleaning disk space"

    # Clean temp
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    # Clean Windows Update cache
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue

    $free = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB
    Write-Log "FIX" "Freed space. C: has ${free}GB free"
    return ($free -gt 5)
}

function Fix-FileLock {
    param($LogContent)
    Write-Log "FIX" "File locked. Waiting for release..."
    Write-Action "Waiting for file lock"
    Start-Sleep -Seconds 10
    return $true
}

function Fix-MSVCTools {
    param($LogContent)
    Write-Log "FIX" "MSVC build tools not found. Installing..."
    Write-Action "Installing VS Build Tools for C++"
    return (Fix-MSBuild $LogContent)
}

function Fix-NpmError {
    param($LogContent)
    Write-Log "FIX" "Clearing npm cache..."
    Write-Action "npm cache clean --force"
    try {
        npm cache clean --force 2>$null
        Remove-Item "node_modules" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "package-lock.json" -Force -ErrorAction SilentlyContinue
        npm install 2>$null
        return $true
    } catch { return $false }
}

function Fix-WindowsSDK {
    param($LogContent)
    Write-Log "FIX" "Windows SDK not found. Install via VS Installer."
    Write-Action "Windows SDK missing"
    return (Fix-MSBuild $LogContent)
}

function Fix-RustBuildScript {
    param($LogContent)
    Write-Log "FIX" "Rust build script failed. Checking dependencies..."
    Write-Action "Checking Rust build dependencies"

    if ($LogContent -match "pkg-config") {
        try { winget install pkg-config -e --accept-package-agreements; return $true } catch { return $false }
    }
    return $false
}

function Install-RustUp {
    Write-Log "FIX" "Downloading and installing rustup..."
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile "$env:TEMP\rustup-init.exe"
    & "$env:TEMP\rustup-init.exe" -y
}

# ─── Notification ─────────────────────────────────────────────────────
function Send-Notification {
    param([string]$Title, [string]$Body, [string]$Level = "Info")

    if (-not $NotifyDesktop) { return }

    # Toast notification (Windows 10+)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("BlueSSH Watchdog").Show($toast)
    } catch {
        # Fallback: balloon tip
        Add-Type -AssemblyName System.Windows.Forms
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 6
        $balloon.Dispose()
    }
}

# ─── Build Execution ──────────────────────────────────────────────────
function Invoke-Build {
    param(
        [string]$Script,
        [int]$Attempt = 1
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFile = Join-Path $LogDir "build_${timestamp}_attempt${Attempt}.log"

    Write-Log "INFO" "═══ Build Attempt #${Attempt} ═══"
    Write-Log "INFO" "Script: $Script"
    Write-Log "INFO" "Log: $logFile"
    Write-Action "Executing $Script (attempt $Attempt)"

    $header = @"
═══════════════════════════════════════════════════
  Build started: $(Get-Date)
  Script: $Script
  Attempt: $Attempt
  User: $env:USERNAME
  PWD: $(Get-Location)
═══════════════════════════════════════════════════

"@
    $header | Out-File -FilePath $logFile -Encoding UTF8

    $startTime = Get-Date
    $exitCode = 0

    try {
        $process = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$Script`"" `
            -RedirectStandardOutput "$logFile.stdout" `
            -RedirectStandardError "$logFile.stderr" `
            -NoNewWindow -Wait -PassThru
        $exitCode = $process.ExitCode

        # Merge stdout and stderr into log
        Get-Content "$logFile.stdout" -ErrorAction SilentlyContinue | Out-File -Append -FilePath $logFile -Encoding UTF8
        Get-Content "$logFile.stderr" -ErrorAction SilentlyContinue | Out-File -Append -FilePath $logFile -Encoding UTF8
        Remove-Item "$logFile.stdout", "$logFile.stderr" -ErrorAction SilentlyContinue
    } catch {
        $exitCode = 1
        $_.Exception.Message | Out-File -Append -FilePath $logFile -Encoding UTF8
    }

    $duration = ((Get-Date) - $startTime).TotalSeconds
    $footer = @"

═══════════════════════════════════════════════════
  Build finished: $(Get-Date)
  Duration: $([math]::Round($duration))s
  Exit code: $exitCode
═══════════════════════════════════════════════════
"@
    $footer | Out-File -Append -FilePath $logFile -Encoding UTF8
    $exitCode | Out-File -FilePath "$logFile.exitcode" -Encoding UTF8

    return @{ LogFile = $logFile; ExitCode = $exitCode }
}

function Invoke-ErrorAnalysis {
    param([string]$LogFile)

    $content = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return @() }

    $detected = @()
    foreach ($ep in $ErrorPatterns) {
        if ($content -match $ep.Pattern) {
            $detected += $ep
        }
    }
    return $detected
}

function Invoke-Fixes {
    param([string]$LogFile, [array]$Detected)

    if ($Detected.Count -eq 0) { return 0 }

    Write-Log "INFO" "═══ Applying Fixes ═══"
    $content = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
    $fixesApplied = 0

    foreach ($ep in $Detected) {
        Write-Log "WARN" "Detected: $($ep.Description)"
        Write-Log "FIX" "Attempting fix for: $($ep.Description)"

        try {
            $result = & $ep.Fix $content
            if ($result) {
                Write-Log "OK" "Fix applied: $($ep.Description)"
                Write-Action "Fix succeeded: $($ep.Description)"
                $fixesApplied++
            } else {
                Write-Log "ERR" "Fix failed: $($ep.Description)"
                Write-Action "Fix failed: $($ep.Description)"
            }
        } catch {
            Write-Log "ERR" "Fix threw exception: $($_.Exception.Message)"
            Write-Action "Fix exception: $($ep.Description) - $($_.Exception.Message)"
        }
    }

    return $fixesApplied
}

# ─── Build Cycle ──────────────────────────────────────────────────────
function Start-BuildCycle {
    param([string]$Script)

    Write-Log "INFO" "═══ Build Cycle Started ═══"
    Write-Log "INFO" "Target: $Script"
    Write-Action "=== Build cycle started for $Script ==="

    $attempt = 1
    $success = $false

    while ($attempt -le $MaxRetries) {
        $result = Invoke-Build -Script $Script -Attempt $attempt

        if ($result.ExitCode -eq 0) {
            Write-Log "OK" "Build succeeded on attempt #$attempt"
            Write-Action "Build succeeded on attempt #$attempt"
            $success = $true
            break
        }

        Write-Log "ERR" "Build failed (exit code: $($result.ExitCode)) on attempt #$attempt"
        Write-Action "Build failed attempt #$attempt (exit=$($result.ExitCode))"

        $detected = Invoke-ErrorAnalysis -LogFile $result.LogFile

        if ($detected.Count -eq 0) {
            Write-Log "ERR" "No known error patterns detected."
            Write-Action "No fixable patterns found"
            break
        }

        Write-Log "INFO" "Detected $($detected.Count) error pattern(s)"
        $fixes = Invoke-Fixes -LogFile $result.LogFile -Detected $detected

        if ($fixes -eq 0) {
            Write-Log "WARN" "No fixes applied. Stopping."
            Write-Action "No fixes applied, giving up"
            break
        }

        Write-Log "INFO" "Waiting ${RetryDelay}s before retry..."
        Start-Sleep -Seconds $RetryDelay
        $attempt++
    }

    if ($success) {
        Write-Log "OK" "BUILD SUCCEEDED"
        Send-Notification "BlueSSH Build" "Build completed successfully" "Info"
        Write-Action "=== Build cycle SUCCEEDED on attempt $attempt ==="
    } else {
        Write-Log "ERR" "BUILD FAILED"
        Send-Notification "BlueSSH Build FAILED" "Build failed after $MaxRetries attempts" "Error"
        Write-Action "=== Build cycle FAILED after $attempt attempts ==="
    }
}

# ─── File Watcher ─────────────────────────────────────────────────────
function Start-Watcher {
    param([string]$Script)

    if (-not (Test-Path $Script)) {
        Write-Log "ERR" "Watched file does not exist: $Script"
        Write-Log "INFO" "Creating stub..."
        "@echo off`necho Build script placeholder" | Out-File -FilePath $Script -Encoding ASCII
    }

    Write-Log "INFO" "═══ Watchdog Active ═══"
    Write-Log "INFO" "Monitoring: $Script"
    Write-Log "INFO" "Logs: $LogDir"
    Write-Log "INFO" "Press Ctrl+C to stop"
    Write-Host ""

    # Initial build
    Start-BuildCycle -Script $Script

    # FileSystemWatcher
    $folder = Split-Path $Script -Parent
    $filter = Split-Path $Script -Leaf

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $folder
    $watcher.Filter = $filter
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true

    $action = {
        Start-Sleep -Seconds $CooldownSeconds
        Write-Host ""
        $global:BuildTriggered = $true
    }

    Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action | Out-Null

    $global:BuildTriggered = $false

    try {
        while ($true) {
            if ($global:BuildTriggered) {
                $global:BuildTriggered = $false
                Write-Log "INFO" "Change detected in $(Split-Path $Script -Leaf)"
                Write-Action "File modified: $Script"
                Start-BuildCycle -Script $Script
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        $watcher.Dispose()
        Get-EventSubscriber | Unregister-Event
    }
}

# ─── Log Cleanup ──────────────────────────────────────────────────────
function Clear-OldLogs {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem $LogDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
    Get-ChildItem $LogDir -Filter "*.exitcode" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
    Get-ChildItem $LogDir -Filter "*.stdout" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
    Get-ChildItem $LogDir -Filter "*.stderr" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
    Write-Log "INFO" "Cleaned logs older than $LogRetentionDays days"
}

# ─── Entry Point ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  BlueSSH Build Watchdog (Windows)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Load-Patterns
Clear-OldLogs

if ($Daemon) {
    Write-Log "INFO" "Starting watcher in background..."
    Start-Job -ScriptBlock {
        param($Script, $WatchdogDir)
        . (Join-Path $WatchdogDir "watch_windows.ps1")
        Start-Watcher $Script
    } -ArgumentList $WatchedFile, $WatchdogDir | Out-Null
    Write-Log "OK" "Watchdog started as background job"
} else {
    Start-Watcher -Script $WatchedFile
}
