#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# watchdog.sh — 4-tier self-healing process monitor
#
# Designed to run periodically (every 60 seconds) via cron, launchd, or systemd.
#
# Tiers:
#   L1: External process supervisor (launchd/systemd KeepAlive — not this script)
#   L2: Process + port + log freshness checks
#   L3: Diagnostic + remediation (disk, memory, restart)
#   L4: Webhook escalation alert
#
# Usage:
#   watchdog.sh                          # Run health check cycle
#   watchdog.sh --config /path/to.json   # Use custom config file
#   watchdog.sh --help                   # Show usage
#
# Configuration (environment variables or config file):
#   WATCHDOG_PROCESS_NAME    Process name to monitor (default: my-agent)
#   WATCHDOG_PORT            TCP port to check (default: 8080)
#   WATCHDOG_LOG_PATH        Log file to check for freshness (optional)
#   WATCHDOG_WEBHOOK_URL     Webhook URL for L4 alerts (optional)
#   WATCHDOG_SERVICE_LABEL   launchd/systemd service label (optional)

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

readonly STATE_DIR="$AEK_HOME/memory/logs"
readonly STATE_FILE="$STATE_DIR/watchdog-state.json"
readonly LOG_FILE="$STATE_DIR/watchdog.log"

# Configurable parameters (override via env vars)
PROCESS_NAME="${WATCHDOG_PROCESS_NAME:-my-agent}"
WATCH_PORT="${WATCHDOG_PORT:-8080}"
WATCH_LOG="${WATCHDOG_LOG_PATH:-}"
WEBHOOK_URL="${WATCHDOG_WEBHOOK_URL:-}"
SERVICE_LABEL="${WATCHDOG_SERVICE_LABEL:-}"

# Thresholds
readonly LOG_FRESHNESS_THRESHOLD="${WATCHDOG_LOG_FRESHNESS:-300}"   # 5 minutes
readonly L3_FAIL_THRESHOLD="${WATCHDOG_L3_THRESHOLD:-3}"            # Consecutive L2 fails before L3
readonly L4_ALERT_COOLDOWN="${WATCHDOG_ALERT_COOLDOWN:-1800}"       # 30 min between alerts
readonly FORCE_RESTART_THRESHOLD=5                                  # Force restart after N failures

METRICS_DB="${AEK_HOME}/memory/metrics.db"
SCRIPT_NAME="$(basename "$0")"

# === Globals ===
FAIL_COUNT=0
LAST_ALERT_TS=0
LAST_CHECK_TS=0
LAST_STATUS="unknown"

# === Logging ===
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "$LOG_FILE"
}

trim_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local line_count
        line_count="$(wc -l < "$LOG_FILE" | tr -d ' ')"
        if [[ $line_count -gt 5000 ]]; then
            tail -2500 "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# === Metrics helper ===
save_metric() {
    local metric="$1" value="$2" tags="${3:-}"
    if [[ -f "$METRICS_DB" ]]; then
        python3 - "$METRICS_DB" "$metric" "$value" "$tags" <<'PYEOF'
import sqlite3, sys
db, metric, value, tags = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
try:
    conn = sqlite3.connect(db)
    conn.execute("INSERT OR IGNORE INTO metrics (agent,metric,value,tags,timestamp) VALUES ('watchdog',?,?,?,datetime('now'))", (metric, value, tags))
    conn.commit()
    conn.close()
except: pass
PYEOF
    fi
}

# === State management ===
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local state_data
        state_data="$(python3 - "$STATE_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    print(s.get('fail_count', 0))
    print(s.get('last_alert_ts', 0))
    print(s.get('last_status', 'unknown'))
except:
    print(0)
    print(0)
    print('unknown')
PYEOF
)" || true
        if [[ -n "$state_data" ]]; then
            FAIL_COUNT="$(echo "$state_data" | sed -n '1p')"
            LAST_ALERT_TS="$(echo "$state_data" | sed -n '2p')"
            LAST_STATUS="$(echo "$state_data" | sed -n '3p')"
        fi
    fi
}

save_state() {
    local status="$1"
    local now
    now="$(date +%s)"
    local human_ts
    human_ts="$(date '+%Y-%m-%d %H:%M:%S')"

    python3 - "$STATE_FILE" "$FAIL_COUNT" "$LAST_ALERT_TS" "$now" "$status" "$human_ts" <<'PYEOF'
import json, sys
state = {
    'fail_count': int(sys.argv[2]),
    'last_alert_ts': int(sys.argv[3]),
    'last_check_ts': int(sys.argv[4]),
    'last_status': sys.argv[5],
    'last_check_human': sys.argv[6]
}
with open(sys.argv[1], 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
    [[ $? -ne 0 ]] && log "WARN" "Failed to save state"
}

# === Webhook notification ===
send_alert() {
    local message="$1"
    local color="${2:-16711680}"  # Default: red

    if [[ -z "$WEBHOOK_URL" ]]; then
        log "WARN" "No webhook URL configured, cannot send alert"
        return 0
    fi

    # Check cooldown
    local now
    now="$(date +%s)"
    local elapsed=$((now - LAST_ALERT_TS))
    if [[ $elapsed -lt $L4_ALERT_COOLDOWN ]]; then
        local remaining=$((L4_ALERT_COOLDOWN - elapsed))
        log "INFO" "Alert cooldown active (${remaining}s remaining), skipping"
        return 0
    fi

    local payload
    payload=$(python3 - "$message" "$color" "$SCRIPT_NAME" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
msg, color, script = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = {"embeds": [{"title": "Watchdog Alert", "description": msg, "color": color, "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "footer": {"text": f"{script} | L4 escalation"}}]}
print(json.dumps(data))
PYEOF
)

    if curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" 2>/dev/null | grep -q "^2"; then
        log "INFO" "Alert sent successfully"
        LAST_ALERT_TS="$now"
    else
        log "WARN" "Failed to send alert"
    fi
}

# === L2: Health Checks ===

# Check 1: Process exists (exact name match to avoid false positives)
check_process() {
    if pgrep -x "$PROCESS_NAME" &>/dev/null; then
        return 0
    fi

    # Fallback: check via service label
    if [[ -n "$SERVICE_LABEL" ]]; then
        local pid
        if [[ "$(uname)" == "Darwin" ]]; then
            pid="$(launchctl print "$SERVICE_LABEL" 2>/dev/null | grep -o 'pid = [0-9]*' | grep -o '[0-9]*' || true)"
        else
            pid="$(systemctl show "$SERVICE_LABEL" --property=MainPID 2>/dev/null | cut -d= -f2 || true)"
        fi
        if [[ -n "$pid" && "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Check 2: Port listening
check_port() {
    if [[ "$WATCH_PORT" == "0" || -z "$WATCH_PORT" ]]; then
        return 0  # Port check disabled
    fi

    if command -v lsof &>/dev/null; then
        if lsof -iTCP:"$WATCH_PORT" -sTCP:LISTEN -P -n &>/dev/null 2>&1; then
            return 0
        fi
    elif command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ":${WATCH_PORT} " 2>/dev/null; then
            return 0
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":${WATCH_PORT} "; then
            return 0
        fi
    fi

    return 1
}

# Check 3: Log freshness
check_log_freshness() {
    if [[ -z "$WATCH_LOG" || ! -f "$WATCH_LOG" ]]; then
        return 0  # No log to check
    fi

    local now
    now="$(date +%s)"
    local file_mtime

    if [[ "$(uname)" == "Darwin" ]]; then
        file_mtime="$(stat -f %m "$WATCH_LOG" 2>/dev/null || echo 0)"
    else
        file_mtime="$(stat -c %Y "$WATCH_LOG" 2>/dev/null || echo 0)"
    fi

    local age=$((now - file_mtime))

    if [[ $age -gt $LOG_FRESHNESS_THRESHOLD ]]; then
        log "WARN" "Log file is stale: ${age}s old (threshold: ${LOG_FRESHNESS_THRESHOLD}s)"
        return 1
    fi

    return 0
}

# Combined L2 check
run_l2_checks() {
    local failures=()

    if ! check_process; then
        failures+=("process_missing")
    fi

    if ! check_port; then
        failures+=("port_not_listening")
    fi

    if ! check_log_freshness; then
        failures+=("log_stale")
    fi

    if [[ ${#failures[@]} -gt 0 ]]; then
        local fail_str
        fail_str="$(IFS=','; echo "${failures[*]}")"
        log "WARN" "L2 FAIL: ${fail_str}"
        echo "$fail_str"
        return 1
    fi

    return 0
}

# === L3: Diagnostic + Remediation ===
run_l3_diagnostic() {
    log "INFO" "L3: Running diagnostic (${FAIL_COUNT} consecutive failures)..."

    local issues=()
    local fixed=()

    # Check 1: Disk space
    local disk_usage
    disk_usage="$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')"
    if [[ $disk_usage -gt 95 ]]; then
        issues+=("disk_full_${disk_usage}pct")
        log "ERROR" "L3: Disk usage critical: ${disk_usage}%"
    fi

    # Check 2: Memory pressure (macOS) or available memory (Linux)
    if [[ "$(uname)" == "Darwin" ]]; then
        local mem_free
        mem_free="$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | grep -o '[0-9]*' || echo 50)"
        if [[ $mem_free -lt 10 ]]; then
            issues+=("memory_pressure_${mem_free}pct_free")
            log "ERROR" "L3: Memory pressure critical: ${mem_free}% free"
        fi
    else
        local mem_avail
        mem_avail="$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 9999)"
        if [[ $mem_avail -lt 256 ]]; then
            issues+=("low_memory_${mem_avail}MB")
            log "ERROR" "L3: Available memory critical: ${mem_avail}MB"
        fi
    fi

    # Check 3: Recent crashes in log
    if [[ -n "$WATCH_LOG" && -f "$WATCH_LOG" ]]; then
        local recent_crashes
        recent_crashes="$(tail -100 "$WATCH_LOG" | grep -c -iE 'CRASH|FATAL|UNCAUGHT|SIGABRT|SIGSEGV' 2>/dev/null || echo 0)"
        if [[ $recent_crashes -gt 0 ]]; then
            issues+=("recent_crashes_${recent_crashes}")
            log "WARN" "L3: ${recent_crashes} crash indicators in recent log"
        fi
    fi

    # Check 4: Attempt restart
    local needs_restart=false
    local restart_reason=""

    if ! check_process; then
        needs_restart=true
        restart_reason="process_missing"
    elif ! check_port; then
        needs_restart=true
        restart_reason="port_not_listening"
        issues+=("process_alive_but_port_dead")
        log "WARN" "L3: Process exists but port not listening — zombie/stuck state"
    fi

    if $needs_restart; then
        log "INFO" "L3: Attempting restart (reason: ${restart_reason})..."

        if [[ -n "$SERVICE_LABEL" ]]; then
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS: try kickstart first, then bootout+bootstrap
                if launchctl kickstart -k "$SERVICE_LABEL" 2>/dev/null; then
                    log "INFO" "L3: kickstart issued, waiting 8s..."
                    sleep 8
                else
                    log "WARN" "L3: kickstart failed, trying bootout+bootstrap..."
                    launchctl bootout "$SERVICE_LABEL" 2>/dev/null || true
                    sleep 2
                    # Extract plist path from label
                    local plist_name
                    plist_name="$(echo "$SERVICE_LABEL" | sed 's|gui/[0-9]*/||')"
                    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${plist_name}.plist" 2>/dev/null || true
                    sleep 8
                fi
            else
                # Linux: systemctl restart
                systemctl --user restart "$SERVICE_LABEL" 2>/dev/null || \
                    sudo systemctl restart "$SERVICE_LABEL" 2>/dev/null || true
                sleep 8
            fi
        else
            log "WARN" "L3: No service label configured, cannot restart automatically"
            issues+=("no_service_label")
        fi

        if check_process && check_port; then
            fixed+=("service_restarted")
            log "INFO" "L3: Restart successful (process + port verified)"
        elif check_process; then
            fixed+=("service_restarted_partial")
            log "WARN" "L3: Process started but port not yet listening"
        else
            issues+=("restart_failed")
            log "ERROR" "L3: Restart failed — all methods exhausted"
        fi
    fi

    # Force restart on persistent failures
    if [[ $FAIL_COUNT -ge $FORCE_RESTART_THRESHOLD ]] && ! $needs_restart; then
        log "WARN" "L3: ${FAIL_COUNT} consecutive failures — forcing restart as last resort"
        if [[ -n "$SERVICE_LABEL" ]]; then
            if [[ "$(uname)" == "Darwin" ]]; then
                launchctl kickstart -k "$SERVICE_LABEL" 2>/dev/null || true
            else
                systemctl --user restart "$SERVICE_LABEL" 2>/dev/null || true
            fi
            sleep 8
            if check_process; then
                fixed+=("force_restarted")
                log "INFO" "L3: Force restart completed"
            else
                issues+=("force_restart_failed")
                log "ERROR" "L3: Force restart also failed"
            fi
        fi
    fi

    # Report
    if [[ ${#issues[@]} -gt 0 ]]; then
        local issues_str
        issues_str="$(IFS=', '; echo "${issues[*]}")"
        local fixed_str="none"
        if [[ ${#fixed[@]} -gt 0 ]]; then
            fixed_str="$(IFS=', '; echo "${fixed[*]}")"
        fi
        log "INFO" "L3 summary — Issues: ${issues_str} | Fixed: ${fixed_str}"
        echo "${issues_str}"

        if [[ ${#fixed[@]} -gt 0 ]]; then
            return 0  # Fixed something, don't escalate yet
        fi
        return 1  # Couldn't fix, escalate
    fi

    log "INFO" "L3: No system issues found, process may be idle"
    return 0
}

# === L4: Escalation ===
run_l4_escalation() {
    local l2_failures="$1"
    local l3_issues="${2:-none}"

    log "ERROR" "L4: Escalating to webhook alert"

    local message="Process health check FAILING\\n"
    message+="Process: ${PROCESS_NAME}\\n"
    message+="Port: ${WATCH_PORT}\\n"
    message+="Consecutive failures: ${FAIL_COUNT}\\n"
    message+="L2 failures: ${l2_failures}\\n"
    message+="L3 diagnostic: ${l3_issues}\\n"
    message+="Host: $(hostname)\\n"
    message+="Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_alert "$message" "16711680"
}

# === Help ===
show_help() {
    cat <<'EOF'
watchdog.sh — 4-Tier Self-Healing Process Monitor

Usage: watchdog.sh [options]

Options:
  --help, -h             Show this help message

Environment Variables:
  WATCHDOG_PROCESS_NAME  Process name to monitor (default: my-agent)
  WATCHDOG_PORT          TCP port to check (default: 8080, set 0 to disable)
  WATCHDOG_LOG_PATH      Log file for freshness check (optional)
  WATCHDOG_WEBHOOK_URL   Webhook URL for L4 alerts (optional)
  WATCHDOG_SERVICE_LABEL Service label for restart (launchd/systemd)
  WATCHDOG_LOG_FRESHNESS Log freshness threshold in seconds (default: 300)
  WATCHDOG_L3_THRESHOLD  L2 failures before L3 diagnostic (default: 3)
  WATCHDOG_ALERT_COOLDOWN Seconds between alerts (default: 1800)

Tiers:
  L1: External supervisor (launchd/systemd KeepAlive)
  L2: Process, port, and log freshness checks
  L3: System diagnostic + automatic restart
  L4: Webhook alert escalation

Examples:
  # Monitor a process named "my-gateway" on port 3000
  WATCHDOG_PROCESS_NAME=my-gateway WATCHDOG_PORT=3000 watchdog.sh

  # With log freshness check and webhook alerts
  WATCHDOG_PROCESS_NAME=my-agent \
  WATCHDOG_PORT=8080 \
  WATCHDOG_LOG_PATH=/var/log/my-agent.log \
  WATCHDOG_WEBHOOK_URL=https://hooks.example.com/alert \
  watchdog.sh

  # Crontab entry (every minute)
  * * * * * /path/to/watchdog.sh
EOF
    exit 0
}

# ============================================================
# MAIN
# ============================================================
main() {
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

    mkdir -p "$STATE_DIR"

    trim_log
    log "INFO" "Watchdog check started (process=$PROCESS_NAME port=$WATCH_PORT)"

    # Load webhook URL from file if env var not set
    local webhook_file="$AEK_HOME/config/webhook-url.txt"
    if [[ -z "$WEBHOOK_URL" && -f "$webhook_file" ]]; then
        WEBHOOK_URL="$(cat "$webhook_file" | tr -d '[:space:]')"
    fi

    # Load previous state
    load_state

    # --- L2: Run health checks ---
    local l2_result=""
    local l2_exit=0
    l2_result="$(run_l2_checks 2>/dev/null)" || l2_exit=$?

    if [[ $l2_exit -eq 0 ]]; then
        # All healthy
        if [[ $FAIL_COUNT -gt 0 ]]; then
            log "INFO" "Process recovered after ${FAIL_COUNT} failures"
            if [[ $FAIL_COUNT -ge $L3_FAIL_THRESHOLD ]]; then
                send_alert "Process RECOVERED after ${FAIL_COUNT} consecutive failures" "65280"
            fi
        fi
        FAIL_COUNT=0
        save_state "healthy"
        save_metric "process_healthy" 1 "l2"
        log "INFO" "L2: All checks passed"
        exit 0
    fi

    # L2 failed
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "WARN" "L2 failed (consecutive: ${FAIL_COUNT}): ${l2_result}"

    # --- L3: Diagnostic (only if threshold reached) ---
    if [[ $FAIL_COUNT -ge $L3_FAIL_THRESHOLD ]]; then
        local l3_issues=""
        local l3_exit=0
        l3_issues="$(run_l3_diagnostic 2>/dev/null)" || l3_exit=$?

        if [[ $l3_exit -eq 0 ]]; then
            # L3 fixed something or no critical issues
            FAIL_COUNT=0
            save_state "l3_remediated"
            save_metric "process_restart" 1 "l3"
            log "INFO" "L3 completed, fail count reset"
            exit 0
        fi

        # --- L4: Escalation ---
        run_l4_escalation "$l2_result" "$l3_issues"
        save_state "l4_escalated"
    else
        save_state "l2_failing"
        log "INFO" "Waiting for threshold (${FAIL_COUNT}/${L3_FAIL_THRESHOLD}) before L3 diagnostic"
    fi

    exit 0  # Always exit 0 to not trigger restart of watchdog itself
}

main "$@"
