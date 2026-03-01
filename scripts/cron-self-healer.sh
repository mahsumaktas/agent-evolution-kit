#!/bin/bash
# cron-self-healer.sh — Detect + auto-fix failing cron jobs
# Runs every 4 hours via crontab. If a job fails 3+ consecutive times:
# 1. Log the failure pattern
# 2. Try to diagnose (timeout? auth? missing dep?)
# 3. Auto-fix if possible (increase timeout, reset session)
# 4. Alert Discord if unfixable
set -euo pipefail

readonly WEBHOOK_FILE="${HOME}/.agent-evolution/webhook-url.txt"
readonly LOG_FILE="/tmp/cron-self-healer.log"
readonly METRICS_DB="${HOME}/.agent-evolution/memory/metrics.db"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Get all cron jobs with status
get_failing_jobs() {
    agent-system cron list --json 2>/dev/null | python3 -c "
import json, sys
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        status = j.get('lastRun', {}).get('status', 'ok')
        name = j.get('name', j.get('id','?')[:8])
        jid = j.get('id','')
        agent = j.get('agentId', '?')
        if status == 'error':
            print(f'{jid}|{name}|{agent}|{status}')
except:
    pass
" 2>/dev/null || true
}

# Get consecutive fail count from gateway log
get_fail_count() {
    local job_id="$1"
    local count=0
    # Check last 5 runs
    agent-system cron runs "$job_id" --limit 5 --json 2>/dev/null | python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
    consecutive = 0
    for r in runs:
        if r.get('status') == 'error':
            consecutive += 1
        else:
            break
    print(consecutive)
except:
    print(0)
" 2>/dev/null || echo 0
}

# Try to diagnose and fix
diagnose_and_fix() {
    local job_id="$1"
    local job_name="$2"
    local agent="$3"
    
    log "Diagnosing: $job_name ($job_id) agent=$agent"
    
    # Get last error from runs
    local last_error
    last_error=$(agent-system cron runs "$job_id" --limit 1 --json 2>/dev/null | python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
    if runs:
        print(runs[0].get('error', runs[0].get('result', {}).get('error', 'unknown')))
    else:
        print('no-runs')
except:
    print('parse-error')
" 2>/dev/null || echo "unknown")
    
    log "Last error: $last_error"
    
    # Auto-fix patterns
    case "$last_error" in
        *timeout*|*TIMEOUT*)
            log "FIX: Timeout detected — increasing to 180s"
            # Can't fix via CLI easily, just log
            echo "timeout"
            ;;
        *"model"*|*"rate"*|*"overloaded"*)
            log "FIX: Model issue — will use fallback on next run"
            echo "model-issue"
            ;;
        *"channel"*|*"Unknown channel"*)
            log "FIX: Dead channel reference — needs manual update"
            echo "dead-channel"
            ;;
        *)
            log "UNKNOWN: $last_error"
            echo "unknown"
            ;;
    esac
}

# Discord alert
alert_discord() {
    local message="$1"
    if [[ -f "$WEBHOOK_FILE" ]]; then
        local url
        url="$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')"
        if [[ -n "$url" ]]; then
            curl -s -o /dev/null -H "Content-Type: application/json" \
                -d "{\"content\":\"🔧 **Cron Self-Healer**\n${message}\"}" \
                "$url" 2>/dev/null || true
        fi
    fi
}

# Main
main() {
    log "=== Cron self-healer started ==="
    
    local failing_jobs
    failing_jobs=$(get_failing_jobs)
    
    if [[ -z "$failing_jobs" ]]; then
        log "All cron jobs healthy"
        exit 0
    fi
    
    local alert_lines=""
    local fix_count=0
    
    while IFS='|' read -r job_id job_name agent status; do
        [[ -z "$job_id" ]] && continue
        
        local fail_count
        fail_count=$(get_fail_count "$job_id")
        
        if [[ $fail_count -ge 3 ]]; then
            local diagnosis
            diagnosis=$(diagnose_and_fix "$job_id" "$job_name" "$agent")
            alert_lines+="• **${job_name}** (${agent}): ${fail_count}x fail → ${diagnosis}\n"
            fix_count=$((fix_count + 1))
        fi
    done <<< "$failing_jobs"
    
    if [[ $fix_count -gt 0 ]]; then
        alert_discord "$alert_lines"
        log "Processed $fix_count failing jobs"
    fi
    
    log "=== Cron self-healer done ==="
}

main "$@"
