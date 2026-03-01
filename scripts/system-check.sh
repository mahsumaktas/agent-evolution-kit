#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# system-check.sh — System health monitoring and diagnostics
#
# Checks system resources, process health, session files, and memory statistics.
# Provides cleanup recommendations.
#
# Usage:
#   system-check.sh               Full system report (default)
#   system-check.sh --full        Complete system report
#   system-check.sh --quick       Quick process + session check
#   system-check.sh --disk        Disk analysis + cleanup suggestions
#   system-check.sh --cleanup     Cleanup recommendations only

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
MAIN_PROCESS="${WATCHDOG_PROCESS_NAME:-}"
MAIN_PORT="${WATCHDOG_PORT:-}"

# === Colors ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

MODE="${1:---full}"

# === System Info ===
system_info() {
    header "SYSTEM INFO"
    echo "  Hostname: $(hostname)"

    # OS version (cross-platform)
    if command -v sw_vers &>/dev/null; then
        echo "  macOS:    $(sw_vers -productVersion 2>/dev/null || echo '?')"
    elif [[ -f /etc/os-release ]]; then
        echo "  OS:       $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo '?')"
    else
        echo "  OS:       $(uname -s) $(uname -r)"
    fi

    echo "  Node:     $(node --version 2>/dev/null || echo 'not installed')"
    echo "  Python:   $(python3 --version 2>/dev/null || echo 'not installed')"
    echo "  Bash:     ${BASH_VERSION:-unknown}"

    # LLM CLI
    local cli_bin="${CLI_BIN:-$(command -v claude 2>/dev/null || echo '')}"
    if [[ -n "$cli_bin" && -x "$cli_bin" ]]; then
        echo "  LLM CLI:  $($cli_bin --version 2>/dev/null || echo 'found')"
    else
        echo "  LLM CLI:  not found"
    fi

    echo "  Uptime:   $(uptime 2>/dev/null | sed 's/.*up //' | sed 's/,.*//' || echo '?')"
}

# === Disk ===
disk_check() {
    header "DISK STATUS"
    local disk_free disk_pct
    disk_free=$(df -h / | tail -1 | awk '{print $4}')
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')

    if [[ $disk_pct -lt 80 ]]; then
        ok "Disk usage: ${disk_pct}% (${disk_free} free)"
    elif [[ $disk_pct -lt 90 ]]; then
        warn "Disk usage: ${disk_pct}% (${disk_free} free) — cleanup recommended"
    else
        fail "Disk usage: ${disk_pct}% (${disk_free} free) — CRITICAL, cleanup required"
    fi

    # Key directory sizes
    echo "  Key directories:"
    du -sh "$AEK_HOME" 2>/dev/null | awk '{print "    AEK_HOME: "$1}'
    du -sh "$AEK_HOME/memory" 2>/dev/null | awk '{print "    memory/: "$1}'
    du -sh "$AEK_HOME/memory/bridge-logs" 2>/dev/null | awk '{print "    bridge-logs/: "$1}'
}

# === Process ===
process_check() {
    header "PROCESS STATUS"

    if [[ -z "$MAIN_PROCESS" ]]; then
        echo "  No main process configured (set WATCHDOG_PROCESS_NAME)"
        return 0
    fi

    local pid
    pid=$(pgrep -x "$MAIN_PROCESS" 2>/dev/null | head -1 || echo "")
    if [[ -n "$pid" ]]; then
        ok "$MAIN_PROCESS running (PID: $pid)"
    else
        fail "$MAIN_PROCESS is NOT running"
    fi

    # Port check
    if [[ -n "$MAIN_PORT" && "$MAIN_PORT" != "0" ]]; then
        if command -v lsof &>/dev/null; then
            if lsof -iTCP:"$MAIN_PORT" -sTCP:LISTEN -P -n &>/dev/null; then
                ok "Port $MAIN_PORT LISTENING"
            else
                fail "Port $MAIN_PORT NOT LISTENING"
            fi
        fi
    fi
}

# === Memory/Evolution ===
evolution_check() {
    header "EVOLUTION SYSTEM"

    # Trajectory pool
    local traj_count="0"
    if [[ -f "$AEK_HOME/memory/trajectory-pool.json" ]]; then
        traj_count=$(python3 -c "
import json
try:
    with open('$AEK_HOME/memory/trajectory-pool.json') as f:
        pool = json.load(f)
    if isinstance(pool, list):
        print(len(pool))
    else:
        print(len(pool.get('entries', pool.get('trajectories', []))))
except:
    print(0)
" 2>/dev/null || echo "0")
    fi
    echo "  Trajectory pool: $traj_count entries"

    # Reflections
    local ref_count
    ref_count=$({ find "$AEK_HOME/memory/reflections" -name "*.md" 2>/dev/null || true; } | wc -l | tr -d ' ')
    echo "  Reflections: $ref_count files"

    # Knowledge
    local know_count
    know_count=$({ find "$AEK_HOME/memory/knowledge" -name "*.md" 2>/dev/null || true; } | wc -l | tr -d ' ')
    echo "  Knowledge base: $know_count files"

    # Bridge logs
    local bridge_count
    bridge_count=$({ find "$AEK_HOME/memory/bridge-logs" -name "*.json" 2>/dev/null || true; } | wc -l | tr -d ' ')
    echo "  Bridge calls: $bridge_count"

    # Goals
    if [[ -f "$AEK_HOME/memory/goals/active-goals.json" ]]; then
        local goal_count
        goal_count=$(python3 -c "import json; print(len(json.load(open('$AEK_HOME/memory/goals/active-goals.json')).get('goals',[])))" 2>/dev/null || echo "?")
        echo "  Active goals: $goal_count"
    else
        echo "  Active goals: none (no goals file)"
    fi

    # Metrics DB
    if [[ -f "$AEK_HOME/memory/metrics.db" ]]; then
        local metric_count
        metric_count=$(sqlite3 "$AEK_HOME/memory/metrics.db" "SELECT COUNT(*) FROM task_log;" 2>/dev/null || echo "?")
        echo "  Metrics entries: $metric_count"
    else
        echo "  Metrics DB: not initialized"
    fi
}

# === Cron ===
cron_check() {
    header "CRON STATUS"

    local cron_count
    cron_count=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')
    echo "  Active cron jobs: $cron_count"
    crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read -r line; do
        echo "    $line"
    done
}

# === Cleanup Suggestions ===
cleanup_suggest() {
    header "CLEANUP SUGGESTIONS"

    # Old bridge logs
    local old_logs
    old_logs=$(find "$AEK_HOME/memory/bridge-logs" -name "*.json" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    [[ $old_logs -gt 0 ]] && warn "$old_logs bridge logs older than 30 days — can be deleted"

    # Large log files
    local large_logs
    large_logs=$(find "$AEK_HOME" -name "*.log" -size +10M 2>/dev/null | wc -l | tr -d ' ')
    [[ $large_logs -gt 0 ]] && warn "$large_logs log files >10MB — should be rotated"

    # Old predictions
    local old_predictions
    old_predictions=$(find "$AEK_HOME/memory/predictions" -name "*.md" -mtime +60 2>/dev/null | wc -l | tr -d ' ')
    [[ $old_predictions -gt 0 ]] && warn "$old_predictions predictions older than 60 days — can be archived"

    # Old briefings
    local old_briefings
    old_briefings=$(find "$AEK_HOME/memory/briefings" -name "*.md" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    [[ $old_briefings -gt 0 ]] && warn "$old_briefings briefings older than 30 days — can be archived"

    # Temp files
    local tmp_files
    tmp_files=$(find /tmp -maxdepth 1 -name "aek-*" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    [[ $tmp_files -gt 0 ]] && warn "$tmp_files old temp files in /tmp — can be cleaned"

    # Brew cache (macOS)
    if command -v brew &>/dev/null; then
        local brew_cache
        brew_cache=$(du -sh "$(brew --cache)" 2>/dev/null | awk '{print $1}')
        [[ -n "$brew_cache" ]] && echo "  Brew cache: $brew_cache (run 'brew cleanup' to free space)"
    fi

    echo ""
    ok "Cleanup suggestions complete"
}

# === Execute ===
case $MODE in
    --full)
        system_info
        disk_check
        process_check
        cron_check
        evolution_check
        cleanup_suggest
        ;;
    --quick)
        process_check
        evolution_check
        ;;
    --disk)
        disk_check
        cleanup_suggest
        ;;
    --cleanup)
        cleanup_suggest
        ;;
    --help|-h)
        echo "Usage: system-check.sh [--full|--quick|--disk|--cleanup]"
        echo ""
        echo "Modes:"
        echo "  --full     Complete system report (default)"
        echo "  --quick    Process + evolution status only"
        echo "  --disk     Disk analysis + cleanup suggestions"
        echo "  --cleanup  Cleanup recommendations only"
        echo ""
        echo "Environment Variables:"
        echo "  AEK_HOME                  Kit root directory"
        echo "  WATCHDOG_PROCESS_NAME     Main process to check"
        echo "  WATCHDOG_PORT             Port to verify"
        ;;
    *)
        echo "Unknown mode: $MODE"
        exit 1
        ;;
esac

echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') — System check completed"
