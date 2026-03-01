#!/usr/bin/env bash
# cron-watchdog.sh — Cron job health watchdog for Oracle system
# Checks log files for failures, tracks consecutive fail counts, reports status.
# Usage: cron-watchdog.sh [--json] [--alert-only] [--help]

set -euo pipefail

# --- Constants ---
SCRIPT_NAME="cron-watchdog"
STATE_FILE="~/.agent-evolution/memory/cron-health.json"
STALE_THRESHOLD_HOURS=48
ALERT_THRESHOLD=3

# Error patterns (case-insensitive grep)
ERROR_PATTERNS="ERROR|FAIL|error|exception|timeout|crash|FATAL|panic|Traceback|API error|rate limit"

# Job definitions: name|log_path|description
declare -a JOBS=(
    "nightly-scan|/Users/user/agent-system-patchkit/nightly.log|AgentSystem nightly PR scan"
    "daily-check|~/.agent-evolution/memory/bridge-logs/daily-cron.log|Oracle daily check"
    "weekly-cycle|~/.agent-evolution/memory/bridge-logs/weekly-cron.log|Oracle weekly cycle"
    "gateway|~/.agent-evolution/logs/gateway.log|AgentSystem gateway"
    "agent-system-cron|~/.agent-evolution/logs/cron.log|AgentSystem cron jobs"
)

# --- Flags ---
OUTPUT_JSON=false
ALERT_ONLY=false

# --- Functions ---

usage() {
    cat <<'USAGE'
cron-watchdog.sh — Cron job health monitor

Usage:
    cron-watchdog.sh [OPTIONS]

Options:
    --json          Output report as JSON
    --alert-only    Only show failing/stale jobs (suppress healthy ones)
    --help          Show this help message

Monitored jobs:
    nightly-scan    AgentSystem nightly PR scan (/Users/user/agent-system-patchkit/nightly.log)
    daily-check     Oracle daily check (~/.agent-evolution/memory/bridge-logs/daily-cron.log)
    weekly-cycle    Oracle weekly cycle (~/.agent-evolution/memory/bridge-logs/weekly-cron.log)
    gateway         AgentSystem gateway (~/.agent-evolution/logs/gateway.log)
    agent-system-cron   AgentSystem cron jobs (~/.agent-evolution/logs/cron.log)

State file:
    ~/.agent-evolution/memory/cron-health.json

Thresholds:
    Stale:    No activity in 48+ hours
    Alert:    3+ consecutive failures
USAGE
    exit 0
}

# Parse a timestamp from log content. Supports multiple formats:
#   - ISO 8601: 2026-02-28T05:00:00.000+03:00
#   - Header:   === OPENCLAW NIGHTLY SCAN: 2026-02-28 05:00 ===
#   - Bracket:  [2026-02-28 05:00:00]
#   - Plain:    2026-02-28 05:00:00
extract_last_timestamp() {
    local file="$1"
    local job_name="${2:-}"
    local ts=""

    # Job-specific extraction for known formats
    case "$job_name" in
        nightly-scan)
            # Header format: === OPENCLAW NIGHTLY SCAN: 2026-02-28 05:00 ===
            ts=$(grep -oE 'NIGHTLY SCAN: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' "$file" 2>/dev/null | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}')
            if [[ -n "$ts" ]]; then
                echo "${ts}:00"
                return
            fi
            ;;
    esac

    # Try ISO 8601 format (gateway logs)
    ts=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$file" 2>/dev/null | tail -1)
    if [[ -n "$ts" ]]; then
        echo "$ts"
        return
    fi

    # Try generic date-time format
    ts=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$file" 2>/dev/null | tail -1)
    if [[ -n "$ts" ]]; then
        echo "$ts"
        return
    fi

    # Try date-time without seconds
    ts=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' "$file" 2>/dev/null | tail -1)
    if [[ -n "$ts" ]]; then
        echo "${ts}:00"
        return
    fi

    echo ""
}

# Convert timestamp to epoch seconds (macOS compatible)
ts_to_epoch() {
    local ts="$1"
    # Normalize: remove T, truncate fractional/tz
    local normalized
    normalized=$(echo "$ts" | sed -E 's/T/ /; s/\.[0-9]+.*//; s/\+.*//; s/Z$//')
    date -j -f "%Y-%m-%d %H:%M:%S" "$normalized" "+%s" 2>/dev/null || echo "0"
}

# Check how many hours ago a timestamp was
hours_ago() {
    local epoch="$1"
    local now
    now=$(date "+%s")
    if [[ "$epoch" == "0" ]]; then
        echo "999999"
        return
    fi
    echo $(( (now - epoch) / 3600 ))
}

# Count error lines in last run block of a log file
count_recent_errors() {
    local file="$1"
    local job_name="$2"
    local error_count=0

    case "$job_name" in
        nightly-scan)
            # Get content from last "=== OPENCLAW NIGHTLY SCAN" header onwards
            local block
            block=$(awk '/^=== OPENCLAW NIGHTLY SCAN/{buf=""} {buf=buf"\n"$0} END{print buf}' "$file" 2>/dev/null)
            error_count=$(echo "$block" | grep -ciE "$ERROR_PATTERNS" 2>/dev/null || true)
            ;;
        gateway)
            # Last 200 lines, filter out normal WS resume (code 1005/1006 are routine)
            local recent
            recent=$(tail -200 "$file" 2>/dev/null)
            error_count=$(echo "$recent" | grep -ciE "error|exception|crash|FATAL|panic|uncaught" 2>/dev/null || true)
            # Subtract routine WS resumes — those are NOT errors
            local ws_noise
            ws_noise=$(echo "$recent" | grep -ciE "WebSocket connection closed with code (1005|1006)|Attempting resume" 2>/dev/null || true)
            # Only count real errors (non-WS-noise)
            # If all "errors" are just WS noise, count = 0
            ;;
        *)
            # Generic: scan last 100 lines
            error_count=$(tail -100 "$file" 2>/dev/null | grep -ciE "$ERROR_PATTERNS" 2>/dev/null || true)
            ;;
    esac

    echo "${error_count:-0}"
}

# Determine status for gateway: distinguish real errors from WS noise
check_gateway_errors() {
    local file="$1"
    local recent
    recent=$(tail -200 "$file" 2>/dev/null)

    # Real errors: exclude WS resume noise
    local real_errors
    real_errors=$(echo "$recent" | grep -iE "error|exception|crash|FATAL|panic|uncaught" 2>/dev/null \
        | grep -cvE "WebSocket connection closed|Attempting resume|backoff" 2>/dev/null || true)

    echo "${real_errors:-0}"
}

# Load previous state from JSON file
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

# Get a value from state JSON using python (available on macOS)
state_get() {
    local state="$1"
    local job="$2"
    local field="$3"
    local default="$4"

    python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('$job', {}).get('$field', '$default'))
except:
    print('$default')
" <<< "$state"
}

# Save state to JSON file
save_state() {
    local json_content="$1"
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$json_content" > "$STATE_FILE"
}

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_JSON=true ;;
        --alert-only) ALERT_ONLY=true ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $arg"; usage ;;
    esac
done

# --- Main ---

NOW=$(date "+%s")
NOW_ISO=$(date "+%Y-%m-%dT%H:%M:%S")
STATE=$(load_state)

# Results arrays
declare -a RESULT_NAMES=()
declare -a RESULT_LAST_RUNS=()
declare -a RESULT_STATUSES=()
declare -a RESULT_CONSEC_FAILS=()
declare -a RESULT_DESCRIPTIONS=()

TOTAL=0
HEALTHY=0
FAILING=0
STALE=0
ALERTS=""

for job_entry in "${JOBS[@]}"; do
    IFS='|' read -r job_name log_path job_desc <<< "$job_entry"
    TOTAL=$((TOTAL + 1))

    # Expand ~ in path
    log_path="${log_path/#\~/$HOME}"

    # Previous consecutive fail count
    prev_fails=$(state_get "$STATE" "$job_name" "consecutive_fails" "0")

    # Check if log exists
    if [[ ! -f "$log_path" ]]; then
        status="STALE"
        last_run="never"
        consec_fails="$prev_fails"
        STALE=$((STALE + 1))

        RESULT_NAMES+=("$job_name")
        RESULT_LAST_RUNS+=("$last_run")
        RESULT_STATUSES+=("$status")
        RESULT_CONSEC_FAILS+=("$consec_fails")
        RESULT_DESCRIPTIONS+=("$job_desc")
        continue
    fi

    # Extract last timestamp
    last_ts=$(extract_last_timestamp "$log_path" "$job_name")
    if [[ -z "$last_ts" ]]; then
        # Fallback: use file modification time
        last_ts=$(date -r "$log_path" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
    fi

    if [[ -n "$last_ts" ]]; then
        last_run="$last_ts"
        last_epoch=$(ts_to_epoch "$last_ts")
        age_hours=$(hours_ago "$last_epoch")
    else
        last_run="unknown"
        age_hours=999999
    fi

    # Check for errors
    if [[ "$job_name" == "gateway" ]]; then
        error_count=$(check_gateway_errors "$log_path")
    else
        error_count=$(count_recent_errors "$log_path" "$job_name")
    fi

    # Determine status
    if [[ "$age_hours" -ge "$STALE_THRESHOLD_HOURS" ]]; then
        status="STALE"
        consec_fails="$prev_fails"
        STALE=$((STALE + 1))
    elif [[ "$error_count" -gt 0 ]]; then
        status="FAIL"
        consec_fails=$((prev_fails + 1))
        FAILING=$((FAILING + 1))
    else
        status="OK"
        consec_fails=0
        HEALTHY=$((HEALTHY + 1))
    fi

    # Check alert threshold
    if [[ "$consec_fails" -ge "$ALERT_THRESHOLD" ]]; then
        if [[ -n "$ALERTS" ]]; then
            ALERTS="${ALERTS}, "
        fi
        ALERTS="${ALERTS}${job_name} (${consec_fails} consecutive fails)"
    fi

    RESULT_NAMES+=("$job_name")
    RESULT_LAST_RUNS+=("$last_run")
    RESULT_STATUSES+=("$status")
    RESULT_CONSEC_FAILS+=("$consec_fails")
    RESULT_DESCRIPTIONS+=("$job_desc")
done

# --- Build and save new state ---
python3 - "$STATE_FILE" <<PYEOF
import json, sys

state_file = sys.argv[1]
names = """${RESULT_NAMES[*]}""".split()
statuses = """${RESULT_STATUSES[*]}""".split()
consec = """${RESULT_CONSEC_FAILS[*]}""".split()
last_runs = [$(printf '"%s",' "${RESULT_LAST_RUNS[@]}" | sed 's/,$//')]
now = "$NOW_ISO"

state = {}
for i, name in enumerate(names):
    state[name] = {
        "last_run": last_runs[i] if i < len(last_runs) else "unknown",
        "status": statuses[i],
        "consecutive_fails": int(consec[i]) if i < len(consec) else 0,
        "checked_at": now
    }

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF

# --- Output ---
if $OUTPUT_JSON; then
    # JSON output
    python3 <<PYEOF
import json

jobs = []
names = """${RESULT_NAMES[*]}""".split()
statuses = """${RESULT_STATUSES[*]}""".split()
consec = """${RESULT_CONSEC_FAILS[*]}""".split()
last_runs = [$(printf '"%s",' "${RESULT_LAST_RUNS[@]}" | sed 's/,$//')]
descriptions = [$(printf '"%s",' "${RESULT_DESCRIPTIONS[@]}" | sed 's/,$//')]

for i, name in enumerate(names):
    job = {
        "name": name,
        "description": descriptions[i] if i < len(descriptions) else "",
        "last_run": last_runs[i] if i < len(last_runs) else "unknown",
        "status": statuses[i],
        "consecutive_fails": int(consec[i]) if i < len(consec) else 0
    }
    jobs.append(job)

alerts = "$ALERTS"
report = {
    "checked_at": "$NOW_ISO",
    "summary": {
        "total": $TOTAL,
        "healthy": $HEALTHY,
        "failing": $FAILING,
        "stale": $STALE
    },
    "alerts": alerts if alerts else None,
    "jobs": jobs
}

print(json.dumps(report, indent=2))
PYEOF
else
    # Text output
    echo "=== Oracle Cron Watchdog Report ==="
    echo "Checked at: $NOW_ISO"
    echo ""

    for i in "${!RESULT_NAMES[@]}"; do
        status="${RESULT_STATUSES[$i]}"

        # Skip healthy jobs in alert-only mode
        if $ALERT_ONLY && [[ "$status" == "OK" ]]; then
            continue
        fi

        # Status indicator
        case "$status" in
            OK)    indicator="[OK]  " ;;
            FAIL)  indicator="[FAIL]" ;;
            STALE) indicator="[STALE]" ;;
        esac

        echo "$indicator ${RESULT_NAMES[$i]}"
        echo "       Description:      ${RESULT_DESCRIPTIONS[$i]}"
        echo "       Last run:         ${RESULT_LAST_RUNS[$i]}"
        echo "       Consecutive fails: ${RESULT_CONSEC_FAILS[$i]}"
        echo ""
    done

    echo "--- Summary ---"
    echo "Total: $TOTAL | Healthy: $HEALTHY | Failing: $FAILING | Stale: $STALE"

    if [[ -n "$ALERTS" ]]; then
        echo ""
        echo "*** ALERTS ***"
        echo "$ALERTS"
    fi
fi
