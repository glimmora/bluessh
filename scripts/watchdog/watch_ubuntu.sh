#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  watch_ubuntu.sh — Build Watchdog for Linux
#
#  Monitors build_ubuntu.sh for modifications via inotify, executes it,
#  captures output, detects errors, applies fixes, and re-runs if needed.
#
#  Usage:
#    ./watch_ubuntu.sh [--config <path>] [--daemon] [--no-notify]
#
#  Requirements:
#    - inotify-tools (apt install inotify-tools)
#    - sudo access for package installation (auto-fix)
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────
WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${WATCHDOG_DIR}/watchdog.conf"
LOG_DIR="${WATCHDOG_DIR}/logs"
PATTERN_DIR="${WATCHDOG_DIR}/patterns"

# Defaults (overridden by config file)
WATCHED_FILE="/home/blue/projects/BlueSSH/scripts/build_ubuntu.sh"
MAX_RETRIES=3
RETRY_DELAY=5
NOTIFY_EMAIL=""
NOTIFY_DESKTOP=true
LOG_RETENTION_DAYS=30
COOLDOWN_SECONDS=3

# Parse arguments
DAEMON_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        --daemon)  DAEMON_MODE=true; shift ;;
        --no-notify) NOTIFY_DESKTOP=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--config <path>] [--daemon] [--no-notify]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR"

# ─── Color & Formatting ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${DIM}$(ts)${RESET} ${BLUE}[INFO]${RESET}  $*"; }
log_success() { echo -e "${DIM}$(ts)${RESET} ${GREEN}[ OK ]${RESET}  $*"; }
log_warn()    { echo -e "${DIM}$(ts)${RESET} ${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${DIM}$(ts)${RESET} ${RED}[ERR ]${RESET}  $*"; }
log_fix()     { echo -e "${DIM}$(ts)${RESET} ${CYAN}[FIX ]${RESET}  $*"; }
log_header()  { echo -e "\n${BOLD}═══ $* ═══${RESET}"; }

# ─── Logging ──────────────────────────────────────────────────────────
RUN_LOG="${LOG_DIR}/watchdog_$(date +%Y%m%d).log"
ACTION_LOG="${LOG_DIR}/actions_$(date +%Y%m%d).log"

log_to_file() {
    local level="$1"; shift
    echo "$(ts) [$level] $*" >> "$RUN_LOG"
}

log_action() {
    echo "$(ts) [ACTION] $*" >> "$ACTION_LOG"
    log_to_file "ACTION" "$*"
}

# ─── Error Pattern Database ──────────────────────────────────────────
# Each pattern: regex → description → fix function name
# Loaded from patterns/ directory

declare -A ERROR_PATTERNS
declare -A ERROR_DESCRIPTIONS
declare -A ERROR_FIXES
declare -a PATTERN_ORDER=()

load_patterns() {
    # Clear
    ERROR_PATTERNS=()
    ERROR_DESCRIPTIONS=()
    ERROR_FIXES=()
    PATTERN_ORDER=()

    # Load from pattern files
    for pf in "$PATTERN_DIR"/*.patterns; do
        [[ -f "$pf" ]] || continue
        log_info "Loading patterns from $(basename "$pf")"
        while IFS='|' read -r pattern description fix_func; do
            [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
            pattern="${pattern#"${pattern%%[![:space:]]*}"}"
            description="${description#"${description%%[![:space:]]*}"}"
            fix_func="${fix_func#"${fix_func%%[![:space:]]*}"}"
            local key="pat_${#PATTERN_ORDER[@]}"
            ERROR_PATTERNS["$key"]="$pattern"
            ERROR_DESCRIPTIONS["$key"]="$description"
            ERROR_FIXES["$key"]="$fix_func"
            PATTERN_ORDER+=("$key")
        done < "$pf"
    done

    # Inline built-in patterns (fallback)
    local builtin_patterns=(
        "command not found|Missing command|fix_missing_command"
        "No such file or directory|Missing file/directory|fix_missing_path"
        "Permission denied|Permission error|fix_permissions"
        "E: Unable to locate package|Package not found|fix_update_repos"
        "dpkg: error|Package manager error|fix_dpkg_lock"
        "Could not get lock|APT lock held|fix_apt_lock"
        "No space left on device|Disk full|fix_disk_space"
        "fatal: not a git repository|Not a git repo|fix_not_git_repo"
        "error: linker .* not found|Missing linker|fix_install_build_tools"
        "pkg-config .* not found|Missing pkg-config|fix_install_pkgconfig"
        "cmake.*not found|Missing cmake|fix_install_cmake"
        "The following packages have unmet dependencies|Dependency conflict|fix_broken_deps"
        "ImportError|Python import error|fix_python_deps"
        "npm ERR!|npm error|fix_npm_error"
        "ModuleNotFoundError|Python module missing|fix_python_module"
        "cargo: command not found|Rust/Cargo missing|fix_install_rust"
        "flutter: command not found|Flutter missing|fix_install_flutter"
        "javac: .* not found|Java compiler missing|fix_install_java"
        "undefined reference to|Linker error|fix_linker_error"
        "Cannot create directory|Cannot mkdir|fix_mkdir"
    )

    for entry in "${builtin_patterns[@]}"; do
        IFS='|' read -r pattern description fix_func <<< "$entry"
        local key="pat_${#PATTERN_ORDER[@]}"
        ERROR_PATTERNS["$key"]="$pattern"
        ERROR_DESCRIPTIONS["$key"]="$description"
        ERROR_FIXES["$key"]="$fix_func"
        PATTERN_ORDER+=("$key")
    done

    log_info "Loaded ${#PATTERN_ORDER[@]} error patterns"
}

# ─── Fix Functions ────────────────────────────────────────────────────
# Each function returns 0 if the fix was applied successfully, 1 if not.

fix_missing_command() {
    local log_content="$1"
    local cmd
    cmd=$(echo "$log_content" | grep -oP '\S+(?=: command not found)' | head -1)
    [[ -z "$cmd" ]] && return 1

    log_fix "Attempting to install missing command: $cmd"
    log_action "Installing missing command: $cmd"

    # Map common commands to packages
    local pkg="$cmd"
    case "$cmd" in
        gcc|g++|ld|as|ar|nm|objcopy|objdump|strip) pkg="build-essential" ;;
        pkg-config) pkg="pkg-config" ;;
        cmake) pkg="cmake" ;;
        rustc|cargo) curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; return $? ;;
        flutter) log_warn "Flutter requires manual installation"; return 1 ;;
        javac) pkg="default-jdk" ;;
        node) pkg="nodejs" ;;
        npm) pkg="npm" ;;
        python3|python) pkg="python3" ;;
        pip3|pip) pkg="python3-pip" ;;
        git) pkg="git" ;;
        inotifywait) pkg="inotify-tools" ;;
    esac

    sudo apt-get install -y "$pkg" 2>/dev/null && return 0
    return 1
}

fix_missing_path() {
    local log_content="$1"
    local path
    path=$(echo "$log_content" | grep -oP "[^ ':]+\s*: No such file or directory" | head -1 | sed 's/: No such file or directory//')
    [[ -z "$path" ]] && return 1

    log_fix "Missing path detected: $path"
    log_action "Creating missing directory: $path"

    if [[ "$path" == */* ]]; then
        local dir
        dir=$(dirname "$path")
        mkdir -p "$dir" 2>/dev/null && {
            log_fix "Created directory: $dir"
            return 0
        }
    fi
    return 1
}

fix_permissions() {
    local log_content="$1"
    local file
    file=$(echo "$log_content" | grep -oP "[^ ':]+(?=: Permission denied)" | head -1)
    [[ -z "$file" ]] && return 1

    log_fix "Fixing permissions for: $file"
    log_action "chmod +x on $file"

    chmod +x "$file" 2>/dev/null && {
        log_fix "Fixed permissions: $file"
        return 0
    }

    # Try with sudo
    sudo chmod +x "$file" 2>/dev/null && {
        log_fix "Fixed permissions (sudo): $file"
        return 0
    }

    return 1
}

fix_update_repos() {
    log_fix "Updating APT package repositories..."
    log_action "Running apt-get update"
    sudo apt-get update -qq 2>/dev/null && {
        log_fix "APT repositories updated"
        return 0
    }
    return 1
}

fix_dpkg_lock() {
    log_fix "Fixing dpkg lock state..."
    log_action "Running dpkg --configure -a"
    sudo dpkg --configure -a 2>/dev/null
    sudo apt-get install -f -y 2>/dev/null && return 0
    return 1
}

fix_apt_lock() {
    log_fix "Waiting for APT lock to be released..."
    log_action "Waiting for APT lock"
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge 60 ]]; then
            log_warn "APT lock held for 60s, force-releasing..."
            sudo kill -9 "$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | awk '{print $1}')" 2>/dev/null || true
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
            sudo dpkg --configure -a
            return 0
        fi
    done
    return 0
}

fix_disk_space() {
    log_fix "Disk space issue detected. Cleaning up..."
    log_action "Cleaning disk space"

    # Clean apt cache
    sudo apt-get clean 2>/dev/null
    # Remove old logs
    sudo find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    # Remove old snap revisions
    sudo snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' |
        while read -r snapname revision; do
            sudo snap remove "$snapname" --revision="$revision" 2>/dev/null
        done

    local free
    free=$(df / --output=avail -BM | tail -1 | tr -d ' M')
    log_fix "Freed space. Available: ${free}M"
    [[ "$free" -gt 500 ]] && return 0
    return 1
}

fix_not_git_repo() {
    local log_content="$1"
    log_fix "Initializing git repository..."
    log_action "git init"
    git init && return 0
    return 1
}

fix_install_build_tools() {
    log_fix "Installing build-essential and binutils..."
    log_action "apt-get install build-essential"
    sudo apt-get install -y build-essential binutils-dev && return 0
    return 1
}

fix_install_pkgconfig() {
    log_fix "Installing pkg-config..."
    log_action "apt-get install pkg-config"
    sudo apt-get install -y pkg-config && return 0
    return 1
}

fix_install_cmake() {
    log_fix "Installing cmake..."
    log_action "apt-get install cmake"
    sudo apt-get install -y cmake && return 0
    return 1
}

fix_broken_deps() {
    log_fix "Fixing broken dependencies..."
    log_action "apt-get install -f"
    sudo apt-get install -f -y 2>/dev/null
    sudo apt-get autoremove -y 2>/dev/null
    sudo dpkg --configure -a 2>/dev/null
    return 0
}

fix_python_deps() {
    local log_content="$1"
    local module
    module=$(echo "$log_content" | grep -oP "(?<=ImportError: No module named )\S+" | head -1)
    [[ -z "$module" ]] && module=$(echo "$log_content" | grep -oP "(?<=ModuleNotFoundError: No module named ')[^']+" | head -1)
    [[ -z "$module" ]] && return 1

    log_fix "Installing Python module: $module"
    log_action "pip install $module"
    pip3 install --user "$module" 2>/dev/null && return 0
    sudo pip3 install "$module" 2>/dev/null && return 0
    return 1
}

fix_python_module() { fix_python_deps "$1"; }

fix_npm_error() {
    log_fix "Clearing npm cache and retrying..."
    log_action "npm cache clean --force"
    npm cache clean --force 2>/dev/null
    rm -rf node_modules package-lock.json 2>/dev/null
    npm install 2>/dev/null && return 0
    return 1
}

fix_install_rust() {
    log_fix "Installing Rust toolchain..."
    log_action "curl rustup install"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env" 2>/dev/null
    command -v cargo &>/dev/null && return 0
    return 1
}

fix_install_flutter() {
    log_warn "Flutter installation requires manual steps."
    log_warn "Visit: https://docs.flutter.dev/get-started/install/linux"
    return 1
}

fix_install_java() {
    log_fix "Installing Java JDK..."
    log_action "apt-get install default-jdk"
    sudo apt-get install -y default-jdk && return 0
    return 1
}

fix_linker_error() {
    local log_content="$1"
    local lib
    lib=$(echo "$log_content" | grep -oP "(?<=-l)\S+" | tail -1)
    [[ -z "$lib" ]] && return 1

    log_fix "Searching for package providing lib$lib..."
    log_action "apt-file search lib$lib"

    if command -v apt-file &>/dev/null; then
        local pkg
        pkg=$(apt-file search "lib${lib}.so" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$pkg" ]]; then
            log_fix "Installing $pkg for -l$lib"
            sudo apt-get install -y "$pkg" && return 0
        fi
    fi

    # Common library mappings
    case "$lib" in
        ssl) sudo apt-get install -y libssl-dev && return 0 ;;
        crypto) sudo apt-get install -y libssl-dev && return 0 ;;
        z) sudo apt-get install -y zlib1g-dev && return 0 ;;
        pthread) return 0 ;; # usually built-in
        dl) return 0 ;; # usually built-in
        m) return 0 ;; # usually built-in
        rt) return 0 ;; # usually built-in
    esac

    return 1
}

fix_mkdir() {
    local log_content="$1"
    local dir
    dir=$(echo "$log_content" | grep -oP "(?<=mkdir: cannot create directory ')[^']+" | head -1)
    [[ -z "$dir" ]] && return 1

    local parent
    parent=$(dirname "$dir")
    log_fix "Creating parent directory: $parent"
    mkdir -p "$parent" 2>/dev/null && return 0
    return 1
}

# ─── Notification ─────────────────────────────────────────────────────
notify_desktop() {
    [[ "$NOTIFY_DESKTOP" != "true" ]] && return 0

    local title="$1"
    local body="$2"
    local urgency="${3:-normal}"

    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$body" 2>/dev/null && return 0
    fi

    if command -v zenity &>/dev/null; then
        zenity --notification --text="$title\n$body" 2>/dev/null &
        return 0
    fi

    # Fallback: terminal bell + visible message
    echo -e "\a"
    return 0
}

notify_email() {
    [[ -z "$NOTIFY_EMAIL" ]] && return 0

    local subject="$1"
    local body="$2"

    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$NOTIFY_EMAIL" 2>/dev/null && return 0
    fi

    if command -v sendmail &>/dev/null; then
        {
            echo "Subject: $subject"
            echo "To: $NOTIFY_EMAIL"
            echo ""
            echo "$body"
        } | sendmail "$NOTIFY_EMAIL" 2>/dev/null && return 0
    fi

    log_warn "No mail client available for notification"
    return 1
}

# ─── Build Execution ──────────────────────────────────────────────────
execute_build() {
    local script="$1"
    local attempt="${2:-1}"
    local log_file="${LOG_DIR}/build_$(date +%Y%m%d_%H%M%S)_attempt${attempt}.log"

    log_header "Build Attempt #${attempt}"
    log_info "Script: $script"
    log_info "Log:    $log_file"
    log_action "Executing $script (attempt $attempt)"

    local exit_code=0
    local start_time
    start_time=$(date +%s)

    # Execute with full output capture
    {
        echo "═══════════════════════════════════════════════════"
        echo "  Build started: $(date)"
        echo "  Script: $script"
        echo "  Attempt: $attempt"
        echo "  User: $(whoami)"
        echo "  PWD: $(pwd)"
        echo "═══════════════════════════════════════════════════"
        echo ""
    } > "$log_file"

    bash "$script" >> "$log_file" 2>&1 || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    {
        echo ""
        echo "═══════════════════════════════════════════════════"
        echo "  Build finished: $(date)"
        echo "  Duration: ${duration}s"
        echo "  Exit code: $exit_code"
        echo "═══════════════════════════════════════════════════"
    } >> "$log_file"

    echo "$exit_code" > "${log_file}.exitcode"
    echo "$log_file"
}

# ─── Error Analysis ───────────────────────────────────────────────────
analyze_errors() {
    local log_file="$1"
    local -n _detected=$2  # nameref to array

    _detected=()

    if [[ ! -f "$log_file" ]]; then
        return
    fi

    local content
    content=$(cat "$log_file")

    for key in "${PATTERN_ORDER[@]}"; do
        local pattern="${ERROR_PATTERNS[$key]}"
        if echo "$content" | grep -qP "$pattern" 2>/dev/null; then
            _detected+=("$key")
        fi
    done
}

apply_fixes() {
    local log_file="$1"
    local -a detected_keys=("${!2}")
    local fixes_applied=0

    if [[ ${#detected_keys[@]} -eq 0 ]]; then
        return 0
    fi

    log_header "Applying Fixes"
    local content
    content=$(cat "$log_file")

    for key in "${detected_keys[@]}"; do
        local description="${ERROR_DESCRIPTIONS[$key]}"
        local fix_func="${ERROR_FIXES[$key]}"

        log_warn "Detected: $description"
        log_info "Attempting fix: $fix_func"

        if declare -f "$fix_func" &>/dev/null; then
            if "$fix_func" "$content"; then
                log_success "Fix applied: $description"
                log_action "Fix succeeded: $fix_func for $description"
                fixes_applied=$((fixes_applied + 1))
            else
                log_error "Fix failed: $description"
                log_action "Fix failed: $fix_func for $description"
            fi
        else
            log_error "Fix function not found: $fix_func"
            log_action "Fix function not found: $fix_func"
        fi
    done

    return $fixes_applied
}

# ─── Main Build Loop ──────────────────────────────────────────────────
run_build_cycle() {
    local script="$1"

    log_header "Build Cycle Started"
    log_info "Target: $script"
    log_action "=== Build cycle started for $script ==="

    local attempt=1
    local success=false

    while [[ $attempt -le $MAX_RETRIES ]]; do
        # Execute
        local log_file
        log_file=$(execute_build "$script" "$attempt")

        local exit_code
        exit_code=$(cat "${log_file}.exitcode" 2>/dev/null || echo "1")

        if [[ "$exit_code" -eq 0 ]]; then
            log_success "Build succeeded on attempt #${attempt}"
            log_action "Build succeeded on attempt #${attempt}"
            success=true
            break
        fi

        log_error "Build failed (exit code: $exit_code) on attempt #${attempt}"
        log_action "Build failed attempt #$attempt (exit=$exit_code)"

        # Analyze
        local -a detected_keys=()
        analyze_errors "$log_file" detected_keys

        if [[ ${#detected_keys[@]} -eq 0 ]]; then
            log_error "No known error patterns detected. Manual investigation needed."
            log_action "No fixable patterns found"
            break
        fi

        log_info "Detected ${#detected_keys[@]} error pattern(s)"

        # Apply fixes
        local fixes_result=0
        local -a detected_ref=("${detected_keys[@]}")
        apply_fixes "$log_file" detected_ref || fixes_result=$?

        if [[ $fixes_result -eq 0 ]]; then
            log_warn "No fixes were successfully applied. Stopping."
            log_action "No fixes applied, giving up"
            break
        fi

        log_info "Waiting ${RETRY_DELAY}s before retry..."
        sleep "$RETRY_DELAY"

        attempt=$((attempt + 1))
    done

    # Final status
    if [[ "$success" == "true" ]]; then
        log_header "BUILD SUCCEEDED"
        notify_desktop "BlueSSH Build" "Build completed successfully" "normal"
        notify_email "[BlueSSH] Build Succeeded" "Build $script completed successfully on attempt $attempt."
        log_action "=== Build cycle SUCCEEDED on attempt $attempt ==="
    else
        log_header "BUILD FAILED"
        notify_desktop "BlueSSH Build FAILED" "Build failed after $MAX_RETRIES attempts" "critical"
        notify_email "[BlueSSH] Build FAILED" "Build $script failed after $attempt attempts. Check $LOG_DIR for details."
        log_action "=== Build cycle FAILED after $attempt attempts ==="
    fi
}

# ─── File Watcher ─────────────────────────────────────────────────────
start_watcher() {
    local script="$1"

    if ! command -v inotifywait &>/dev/null; then
        log_error "inotifywait not found. Installing inotify-tools..."
        sudo apt-get install -y inotify-tools
    fi

    if [[ ! -f "$script" ]]; then
        log_error "Watched file does not exist: $script"
        log_info "Creating stub..."
        echo '#!/usr/bin/env bash' > "$script"
        chmod +x "$script"
    fi

    log_header "Watchdog Active"
    log_info "Monitoring: $script"
    log_info "Logs: $LOG_DIR"
    log_info "Press Ctrl+C to stop"
    echo ""

    # Run initial build
    run_build_cycle "$script"

    # Watch loop
    while true; do
        log_info "Waiting for changes to $(basename "$script")..."

        inotifywait -q -e modify,move_to,create "$script" 2>/dev/null

        sleep "$COOLDOWN_SECONDS"

        log_info "Change detected in $(basename "$script")"
        log_action "File modified: $script"

        run_build_cycle "$script"
    done
}

# ─── Cleanup ──────────────────────────────────────────────────────────
cleanup_old_logs() {
    find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    find "$LOG_DIR" -name "*.exitcode" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    log_info "Cleaned logs older than ${LOG_RETENTION_DAYS} days"
}

# ─── Entry Point ──────────────────────────────────────────────────────
main() {
    log_header "BlueSSH Build Watchdog (Linux)"
    log_info "PID: $$"

    load_patterns
    cleanup_old_logs

    if [[ "$DAEMON_MODE" == "true" ]]; then
        log_info "Starting in daemon mode..."
        start_watcher "$WATCHED_FILE" &
        local watcher_pid=$!
        echo "$watcher_pid" > "${LOG_DIR}/watchdog.pid"
        log_success "Daemon started (PID: $watcher_pid)"
        log_info "PID file: ${LOG_DIR}/watchdog.pid"
        log_info "Stop with: kill \$(cat ${LOG_DIR}/watchdog.pid)"
    else
        start_watcher "$WATCHED_FILE"
    fi
}

main "$@"
