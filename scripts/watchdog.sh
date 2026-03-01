#!/bin/bash
# watchdog.sh — 4-tier self-healing for AgentSystem gateway
# Designed to run every 60 seconds via launchd.
#
# L1: launchd KeepAlive (external, already exists)
# L2: Process + port + log freshness checks (this script)
# L3: Diagnostic + remediation (disk, memory, log analysis)
# L4: Discord escalation alert
set -euo pipefail

# --- Constants ---
readonly STATE_FILE="/tmp/watchdog-state.json"
readonly LOG_FILE="/tmp/watchdog.log"
readonly WEBHOOK_FILE="${HOME}/.agent-evolution/webhook-url.txt"
readonly GATEWAY_LABEL="gui/$(id -u)/ai.agent-system.gateway"
readonly GATEWAY_PORT=28643
readonly GATEWAY_WS_PORT=28645
readonly LOG_FRESHNESS_THRESHOLD=300   # 5 minutes — detect outages faster
L3_FAIL_THRESHOLD=3          # Consecutive L2 fails before L3 — overridden by restart policy
readonly L4_ALERT_COOLDOWN=1800       # 30 minutes between Discord alerts
readonly SCRIPT_NAME="$(basename "$0")"
readonly METRICS_DB="${HOME}/.agent-evolution/memory/metrics.db"
readonly BLACKBOARD_SCRIPT="${HOME}/.agent-evolution/scripts/blackboard.sh"
readonly RESTART_POLICY_FILE="${HOME}/.agent-evolution/config/restart-policies.yaml"

# --- Restart policy defaults (overridden by config) ---
POLICY_MAX_RESTARTS=5
POLICY_MAX_CONSECUTIVE_FAILURES=3
POLICY_COOLDOWN_SECONDS=2
POLICY_BACKOFF="exponential"
POLICY_MAX_BACKOFF_SECONDS=60
POLICY_STABILITY_RESET_SECONDS=300
POLICY_PERMANENTLY_DEAD_ACTION="alert_operator"

# --- Supervisor state tracking ---
TOTAL_RESTARTS=0
LAST_STABLE_TIME=0

# --- Load restart policy from YAML ---
load_restart_policy() {
    local agent_name="${1:-agent-system-gateway}"

    if [[ ! -f "$RESTART_POLICY_FILE" ]]; then
        log "WARN" "Restart policy file not found: ${RESTART_POLICY_FILE}, using defaults"
        return 0
    fi

    # Parse YAML with Python (simple key-value extraction)
    eval "$(python3 - "$RESTART_POLICY_FILE" "$agent_name" <<'PYEOF'
import sys

config_path = sys.argv[1]
agent_name = sys.argv[2]

with open(config_path) as f:
    lines = f.readlines()

# Simple YAML parser: find agent block, extract values
current_agent = None
agents_section = False
values = {}
default_values = {}

for line in lines:
    stripped = line.rstrip()
    if not stripped or stripped.startswith('#'):
        continue

    indent = len(line) - len(line.lstrip())

    if stripped == 'agents:':
        agents_section = True
        continue

    if agents_section and indent == 2 and stripped.endswith(':'):
        current_agent = stripped.rstrip(':').strip()
        continue

    if agents_section and indent == 4 and current_agent and ':' in stripped:
        key, val = stripped.split(':', 1)
        key = key.strip()
        val = val.strip()
        if current_agent == agent_name:
            values[key] = val
        elif current_agent == 'default':
            default_values[key] = val

# Merge: agent-specific overrides default
merged = {**default_values, **values}

field_map = {
    'max_restarts': 'POLICY_MAX_RESTARTS',
    'max_consecutive_failures': 'POLICY_MAX_CONSECUTIVE_FAILURES',
    'cooldown_seconds': 'POLICY_COOLDOWN_SECONDS',
    'backoff': 'POLICY_BACKOFF',
    'max_backoff_seconds': 'POLICY_MAX_BACKOFF_SECONDS',
    'stability_reset_seconds': 'POLICY_STABILITY_RESET_SECONDS',
    'permanently_dead_action': 'POLICY_PERMANENTLY_DEAD_ACTION',
}

for yaml_key, bash_var in field_map.items():
    if yaml_key in merged:
        v = merged[yaml_key]
        print(f'{bash_var}="{v}"')
PYEOF
)" 2>/dev/null || log "WARN" "Failed to parse restart policy, using defaults"

    log "INFO" "Policy loaded for '${agent_name}': max_restarts=${POLICY_MAX_RESTARTS}, max_consecutive=${POLICY_MAX_CONSECUTIVE_FAILURES}, backoff=${POLICY_BACKOFF}, cooldown=${POLICY_COOLDOWN_SECONDS}s"
}

# --- Backoff calculation ---
calculate_backoff() {
    local attempt="$1"
    local delay

    if [[ "$POLICY_BACKOFF" == "exponential" ]]; then
        # cooldown * 2^(attempt-1), capped at max_backoff
        delay=$(python3 -c "print(min(${POLICY_COOLDOWN_SECONDS} * (2 ** (${attempt} - 1)), ${POLICY_MAX_BACKOFF_SECONDS}))" 2>/dev/null || echo "$POLICY_COOLDOWN_SECONDS")
    else
        # linear: cooldown * attempt, capped at max_backoff
        delay=$(( POLICY_COOLDOWN_SECONDS * attempt ))
        if [[ $delay -gt $POLICY_MAX_BACKOFF_SECONDS ]]; then
            delay=$POLICY_MAX_BACKOFF_SECONDS
        fi
    fi

    echo "$delay"
}

# --- Metrics helper ---
save_metric() {
    local metric="$1" value="$2" tags="${3:-}"
    sqlite3 "$METRICS_DB" \
        "INSERT OR IGNORE INTO metrics (agent,metric,value,tags,timestamp) VALUES ('watchdog','$metric',$value,'$tags',datetime('now'));" 2>/dev/null || true
}

# --- Globals ---
DISCORD_WEBHOOK_URL=""
FAIL_COUNT=0
LAST_ALERT_TS=0
LAST_CHECK_TS=0
LAST_STATUS="unknown"

# --- Logging ---
log() {
    local level="$1"; shift
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" >> "$LOG_FILE"
}

# Keep log file from growing forever (max 5000 lines)
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

# --- State management ---
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # Parse JSON state file (jq-free for minimal dependencies)
        FAIL_COUNT="$(python3 -c "
import json, sys
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('fail_count', 0))
except: print(0)
" 2>/dev/null || echo 0)"

        LAST_ALERT_TS="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('last_alert_ts', 0))
except: print(0)
" 2>/dev/null || echo 0)"

        LAST_CHECK_TS="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('last_check_ts', 0))
except: print(0)
" 2>/dev/null || echo 0)"

        LAST_STATUS="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('last_status', 'unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")"

        TOTAL_RESTARTS="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('total_restarts', 0))
except: print(0)
" 2>/dev/null || echo 0)"

        LAST_STABLE_TIME="$(python3 -c "
import json
try:
    s = json.load(open('${STATE_FILE}'))
    print(s.get('last_stable_time', 0))
except: print(0)
" 2>/dev/null || echo 0)"
    fi
}

save_state() {
    local status="$1"
    local now
    now="$(date +%s)"

    python3 -c "
import json
state = {
    'fail_count': ${FAIL_COUNT},
    'last_alert_ts': ${LAST_ALERT_TS},
    'last_check_ts': ${now},
    'last_status': '${status}',
    'last_check_human': '$(date '+%Y-%m-%d %H:%M:%S')',
    'total_restarts': ${TOTAL_RESTARTS},
    'last_stable_time': ${LAST_STABLE_TIME}
}
with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || log "WARN" "Failed to save state"
}

# --- Discord notification ---
send_discord_alert() {
    local message="$1"
    local color="${2:-16711680}"  # Default: red

    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        log "WARN" "No Discord webhook, cannot send alert"
        return 0
    fi

    # Check cooldown
    local now
    now="$(date +%s)"
    local elapsed=$((now - LAST_ALERT_TS))
    if [[ $elapsed -lt $L4_ALERT_COOLDOWN ]]; then
        local remaining=$((L4_ALERT_COOLDOWN - elapsed))
        log "INFO" "Alert cooldown active (${remaining}s remaining), skipping Discord"
        return 0
    fi

    local payload
    payload=$(cat <<JSONEOF
{
  "embeds": [{
    "title": "Oracle Watchdog Alert",
    "description": "${message}",
    "color": ${color},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "footer": {"text": "watchdog.sh | L4 escalation"}
  }]
}
JSONEOF
)

    if curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK_URL" 2>/dev/null | grep -q "^2"; then
        log "INFO" "Discord alert sent successfully"
        LAST_ALERT_TS="$now"
    else
        log "WARN" "Failed to send Discord alert"
    fi
}

# --- L2: Health checks ---

# Check 1: Gateway process exists
# CRITICAL: Use exact process name match to avoid false positives from
# tail -f, grep, or other processes that contain "agent-system" in args.
# The actual gateway process is named "agent-system-gateway" (confirmed via ps -eo pid,comm).
check_process() {
    # Primary: exact process name match
    if pgrep -x "agent-system-gateway" &>/dev/null; then
        return 0
    fi

    # Secondary: launchctl PID check (handles renamed binaries)
    local pid
    pid="$(launchctl print "$GATEWAY_LABEL" 2>/dev/null | grep -o 'pid = [0-9]*' | grep -o '[0-9]*' || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Check 2: Port listening
check_port() {
    # Check if gateway port is listening (TCP)
    if lsof -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN -P -n &>/dev/null 2>&1; then
        return 0
    fi
    # Also check WS port
    if lsof -iTCP:"$GATEWAY_WS_PORT" -sTCP:LISTEN -P -n &>/dev/null 2>&1; then
        return 0
    fi
    # No pgrep fallback — if ports aren't listening, that's a real failure.
    # Previous pgrep -f "agent-system" matched tail/grep processes (false positive).
    return 1
}

# Check 3: Log freshness
check_log_freshness() {
    local log_file=""

    # Find the gateway log
    for candidate in \
        "${HOME}/.agent-evolution/logs/gateway.log" \
        "${HOME}/.agent-evolution/logs/stderr.log" \
        "${HOME}/.agent-evolution/gateway-stderr.log"; do
        if [[ -f "$candidate" ]]; then
            log_file="$candidate"
            break
        fi
    done

    if [[ -z "$log_file" ]]; then
        # Try launchd plist
        local plist_stderr
        plist_stderr="$(defaults read "${HOME}/Library/LaunchAgents/ai.agent-system.gateway" StandardErrorPath 2>/dev/null || true)"
        if [[ -n "$plist_stderr" && -f "$plist_stderr" ]]; then
            log_file="$plist_stderr"
        fi
    fi

    if [[ -z "$log_file" ]]; then
        log "WARN" "Cannot find gateway log file for freshness check"
        return 0  # Don't fail on missing log
    fi

    local now
    now="$(date +%s)"
    local file_mtime
    file_mtime="$(stat -f %m "$log_file" 2>/dev/null || echo 0)"
    local age=$((now - file_mtime))

    if [[ $age -gt $LOG_FRESHNESS_THRESHOLD ]]; then
        log "WARN" "Gateway log is stale: ${age}s old (threshold: ${LOG_FRESHNESS_THRESHOLD}s)"
        return 1
    fi

    return 0
}


# Check 4: Chrome CDP health (port 18804)
check_cdp() {
    local cdp_port=18804
    if curl -s --max-time 3 "http://127.0.0.1:${cdp_port}/json/version" >/dev/null 2>&1; then
        return 0
    fi
    
    log "WARN" "CDP port ${cdp_port} not responding, attempting restart..."
    
    # Kill stale Chrome-CDP processes
    pkill -f "remote-debugging-port=${cdp_port}" 2>/dev/null || true
    sleep 2
    
    # Restart via launcher script
    if [[ -x "${HOME}/bin/chrome-debug-launcher.sh" ]]; then
        bash "${HOME}/bin/chrome-debug-launcher.sh" >> /tmp/chrome-cdp.log 2>&1
        sleep 3
        if curl -s --max-time 3 "http://127.0.0.1:${cdp_port}/json/version" >/dev/null 2>&1; then
            log "INFO" "CDP auto-recovered on port ${cdp_port}"
            save_metric "cdp_restart" 1 "auto"
            return 0
        fi
    fi
    
    log "ERROR" "CDP auto-recovery failed"
    save_metric "cdp_fail" 1 "auto"
    return 1
}

# Check 5: Session bloat auto-archive (>2MB sessions cause repeat-answer bugs)
check_session_bloat() {
    local sessions_dir="${HOME}/.agent-evolution/agents"
    local archive_dir="${HOME}/.agent-evolution/session-archive/auto-$(date +%Y%m%d)"
    local bloated=0

    while IFS= read -r f; do
        local size_bytes
        size_bytes=$(stat -f %z "$f" 2>/dev/null || echo 0)
        if [[ $size_bytes -gt 2097152 ]]; then  # 2MB
            local agent session_id size_human
            agent=$(echo "$f" | sed 's|.*/agents/||;s|/sessions/.*||')
            session_id=$(basename "$f" .jsonl)
            size_human=$(ls -lh "$f" | awk '{print $5}')
            log "WARN" "Bloated session: ${agent}/${session_id} (${size_human})"

            mkdir -p "$archive_dir"
            mv "$f" "$archive_dir/"
            bloated=$((bloated + 1))

            # Remove from sessions.json mapping
            local sessions_json="${HOME}/.agent-evolution/agents/${agent}/sessions/sessions.json"
            if [[ -f "$sessions_json" ]]; then
                python3 - "$sessions_json" "$session_id" <<'PYEOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
to_remove = [k for k,v in d.items() if isinstance(v,dict) and v.get('sessionId','').startswith(sid[:8])]
for k in to_remove: del d[k]
if to_remove:
    with open(path,'w') as f: json.dump(d, f, indent=2)
PYEOF
            fi

            log "INFO" "Auto-archived bloated session: ${agent}/${session_id}"
            save_metric "session_bloat_archived" 1 "agent:${agent}"
        fi
    done < <(find "$sessions_dir" -name "*.jsonl" -size +2M 2>/dev/null)

    if [[ $bloated -gt 0 ]]; then
        log "WARN" "Archived ${bloated} bloated session(s). Gateway restart recommended."
        send_discord_alert "Auto-archived ${bloated} bloated session(s) (>2MB). Repeat-answer bug prevention." "16776960"
        bash "$BLACKBOARD_SCRIPT" set "session:last_bloat_archive" "$(date +%s)" 2>/dev/null || true
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

    if ! check_cdp; then
        failures+=("cdp_down")
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

# --- L3: Diagnostic + remediation ---
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

        # Try to free space: clean old sandbox/deploy backups
        if [[ -d "/tmp/sandbox-"* ]] 2>/dev/null; then
            find /tmp -maxdepth 1 -name "sandbox-*" -mtime +1 -exec rm -rf {} \; 2>/dev/null || true
            fixed+=("cleaned_old_sandboxes")
        fi
        if [[ -d "/tmp/deploy-backups" ]]; then
            find /tmp/deploy-backups -maxdepth 1 -mindepth 1 -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
            fixed+=("cleaned_old_backups")
        fi
    fi

    # Check 2: Memory pressure
    local mem_pressure
    mem_pressure="$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | grep -o '[0-9]*' || echo 50)"
    if [[ $mem_pressure -lt 10 ]]; then
        issues+=("memory_pressure_${mem_pressure}pct_free")
        log "ERROR" "L3: Memory pressure critical: ${mem_pressure}% free"
    fi

    # Check 3: Gateway crash in recent log
    local recent_crashes=0
    for log_candidate in \
        "${HOME}/.agent-evolution/logs/gateway.log" \
        "${HOME}/.agent-evolution/logs/stderr.log"; do
        if [[ -f "$log_candidate" ]]; then
            recent_crashes="$(tail -100 "$log_candidate" | grep -c -iE 'CRASH|FATAL|UNCAUGHT|SIGABRT|SIGSEGV' 2>/dev/null || echo 0)"
            break
        fi
    done

    if [[ $recent_crashes -gt 0 ]]; then
        issues+=("recent_crashes_${recent_crashes}")
        log "WARN" "L3: ${recent_crashes} crash indicators in recent log"
    fi

    # Check 4: Session file corruption (>1MB = trouble)
    local session_dir="${HOME}/.agent-evolution/sessions"
    if [[ -d "$session_dir" ]]; then
        local large_sessions
        large_sessions="$(find "$session_dir" -name '*.jsonl' -size +1M 2>/dev/null | wc -l | tr -d ' ')"
        if [[ $large_sessions -gt 0 ]]; then
            issues+=("large_sessions_${large_sessions}")
            log "WARN" "L3: ${large_sessions} session file(s) > 1MB (may cause incomplete thinking drops)"
        fi
    fi

    # Check 5: Gateway restart — try if process missing OR port not listening
    # Both conditions indicate the gateway is non-functional even if something
    # named "agent-system" exists (e.g. zombie, stuck supervisor).
    local needs_restart=false
    local restart_reason=""

    if ! check_process; then
        needs_restart=true
        restart_reason="process_missing"
    elif ! check_port; then
        needs_restart=true
        restart_reason="port_not_listening"
        issues+=("process_alive_but_port_dead")
        log "WARN" "L3: Gateway process exists but port not listening — zombie/stuck state"
    fi

    if $needs_restart; then
        TOTAL_RESTARTS=$((TOTAL_RESTARTS + 1))
        local backoff_delay
        backoff_delay="$(calculate_backoff "$TOTAL_RESTARTS")"
        log "INFO" "L3: Attempting gateway restart #${TOTAL_RESTARTS}/${POLICY_MAX_RESTARTS} (reason: ${restart_reason}, backoff: ${backoff_delay}s, type: ${POLICY_BACKOFF})..."

        # Apply backoff delay before restart
        if [[ $backoff_delay -gt 0 ]]; then
            log "INFO" "L3: Backoff delay ${backoff_delay}s before restart..."
            sleep "$backoff_delay"
        fi

        # Step 1: Try kickstart (works even if process exited with 0)
        if launchctl kickstart -k "$GATEWAY_LABEL" 2>/dev/null; then
            log "INFO" "L3: kickstart issued, waiting 8s for startup..."
            sleep 8
        else
            # kickstart failed — try bootout+bootstrap
            log "WARN" "L3: kickstart failed, trying bootout+bootstrap..."
            launchctl bootout "$GATEWAY_LABEL" 2>/dev/null || true
            sleep 2
            launchctl bootstrap "gui/$(id -u)" "${HOME}/Library/LaunchAgents/ai.agent-system.gateway.plist" 2>/dev/null || true
            sleep 8
        fi

        if check_process && check_port; then
            fixed+=("gateway_restarted")
            log "INFO" "L3: Gateway restart #${TOTAL_RESTARTS} successful (process + port verified)"
            save_metric "gateway_restart" 1 "attempt:${TOTAL_RESTARTS},backoff:${backoff_delay}"
        elif check_process; then
            fixed+=("gateway_restarted_partial")
            log "WARN" "L3: Gateway process started but port not yet listening (may need more time)"
        else
            issues+=("gateway_restart_failed")
            log "ERROR" "L3: Gateway restart #${TOTAL_RESTARTS} failed — all methods exhausted"
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

        # If we fixed something, give it a chance
        if [[ ${#fixed[@]} -gt 0 ]]; then
            return 0  # Fixed something, don't escalate yet
        fi
        return 1  # Couldn't fix, escalate
    fi

    # If L2 keeps failing but L3 can't find any system issue AND restart wasn't needed,
    # still try a restart — the gateway might be in a weird state (log stale but process alive).
    if [[ $FAIL_COUNT -ge $((L3_FAIL_THRESHOLD + 2)) ]]; then
        TOTAL_RESTARTS=$((TOTAL_RESTARTS + 1))
        local force_backoff
        force_backoff="$(calculate_backoff "$TOTAL_RESTARTS")"
        log "WARN" "L3: ${FAIL_COUNT} consecutive failures with no detected issues — force restart #${TOTAL_RESTARTS} (backoff: ${force_backoff}s)"

        if [[ $force_backoff -gt 0 ]]; then
            sleep "$force_backoff"
        fi
        launchctl kickstart -k "$GATEWAY_LABEL" 2>/dev/null || true
        sleep 8
        if check_process; then
            fixed+=("gateway_force_restarted")
            log "INFO" "L3: Force restart #${TOTAL_RESTARTS} completed"
            save_metric "gateway_force_restart" 1 "attempt:${TOTAL_RESTARTS}"
            echo "force_restarted"
            return 0
        else
            log "ERROR" "L3: Force restart #${TOTAL_RESTARTS} also failed"
            echo "force_restart_failed"
            return 1
        fi
    fi

    log "INFO" "L3: No system issues found, gateway may be idle"
    return 0
}

# --- L4: Discord escalation ---
run_l4_escalation() {
    local l2_failures="$1"
    local l3_issues="${2:-none}"

    log "ERROR" "L4: Escalating to Discord alert"

    local message="Gateway health check FAILING\\n"
    message+="Consecutive failures: ${FAIL_COUNT}\\n"
    message+="L2 failures: ${l2_failures}\\n"
    message+="L3 diagnostic: ${l3_issues}\\n"
    message+="Host: $(hostname)\\n"
    message+="Time: $(date '+%Y-%m-%d %H:%M:%S')"

    send_discord_alert "$message" "16711680"
}

# ============================================================
# MAIN
# ============================================================
main() {
    trim_log
    log "INFO" "Watchdog check started"

    # Load webhook
    if [[ -f "$WEBHOOK_FILE" ]]; then
        DISCORD_WEBHOOK_URL="$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')"
    fi

    # Load restart policy from config (BEFORE state load)
    load_restart_policy "agent-system-gateway"
    L3_FAIL_THRESHOLD="$POLICY_MAX_CONSECUTIVE_FAILURES"

    # Load previous state
    load_state

    # --- Stability reset: if running long enough without failure, reset counters ---
    if [[ $LAST_STABLE_TIME -gt 0 ]]; then
        local stable_duration=$(( $(date +%s) - LAST_STABLE_TIME ))
        if [[ $stable_duration -ge $POLICY_STABILITY_RESET_SECONDS && $FAIL_COUNT -eq 0 ]]; then
            log "INFO" "Stability reset: agent stable for ${stable_duration}s (threshold: ${POLICY_STABILITY_RESET_SECONDS}s), resetting total_restarts"
            TOTAL_RESTARTS=0
            save_metric "stability_reset" 1 "stable_duration:${stable_duration}"
        fi
    fi

    # --- PermanentlyDead check ---
    if [[ $TOTAL_RESTARTS -ge $POLICY_MAX_RESTARTS ]]; then
        log "ERROR" "PermanentlyDead: total_restarts (${TOTAL_RESTARTS}) >= max_restarts (${POLICY_MAX_RESTARTS}). Skipping restart."
        if [[ "$POLICY_PERMANENTLY_DEAD_ACTION" == "alert_operator" ]]; then
            send_discord_alert "PERMANENTLY DEAD: Gateway exceeded max restarts (${TOTAL_RESTARTS}/${POLICY_MAX_RESTARTS}). Manual intervention required." "16711680"
        else
            log "WARN" "PermanentlyDead action: ${POLICY_PERMANENTLY_DEAD_ACTION}"
        fi
        save_state "permanently_dead"
        save_metric "permanently_dead" 1 "total_restarts:${TOTAL_RESTARTS}"
        exit 0
    fi

    # --- Session bloat check (independent, non-blocking) ---
    check_session_bloat 2>/dev/null || true

    # --- L2: Run health checks ---
    local l2_result=""
    local l2_exit=0
    l2_result="$(run_l2_checks 2>/dev/null)" || l2_exit=$?

    if [[ $l2_exit -eq 0 ]]; then
        # All healthy
        if [[ $FAIL_COUNT -gt 0 ]]; then
            log "INFO" "Gateway recovered after ${FAIL_COUNT} failures"
            if [[ $FAIL_COUNT -ge $L3_FAIL_THRESHOLD ]]; then
                send_discord_alert "Gateway RECOVERED after ${FAIL_COUNT} consecutive failures" "65280"
            fi
        fi
        FAIL_COUNT=0
        # Track stable time: set when first healthy after failure, or keep existing
        if [[ $LAST_STABLE_TIME -eq 0 ]]; then
            LAST_STABLE_TIME=$(date +%s)
        fi
        save_state "healthy"
        save_metric "gateway_healthy" 1 "l2"
        log "INFO" "L2: All checks passed"
        exit 0
    fi

    # L2 failed — reset stable time
    FAIL_COUNT=$((FAIL_COUNT + 1))
    LAST_STABLE_TIME=0
    log "WARN" "L2 failed (consecutive: ${FAIL_COUNT}): ${l2_result}"

    # --- L3: Diagnostic (only if threshold reached) ---
    if [[ $FAIL_COUNT -ge $L3_FAIL_THRESHOLD ]]; then
        local l3_issues=""
        local l3_exit=0
        l3_issues="$(run_l3_diagnostic 2>/dev/null)" || l3_exit=$?

        if [[ $l3_exit -eq 0 ]]; then
            # L3 fixed something or no critical issues
            # Reset fail count so we don't keep running L3 every cycle
            FAIL_COUNT=0
            save_state "l3_remediated"
            save_metric "gateway_restart" 1 "l3"
            bash "$BLACKBOARD_SCRIPT" set "gateway:last_restart" "$(date +%s)" 2>/dev/null || true
            log "INFO" "L3 completed, fail count reset, waiting for next check"
            exit 0
        fi

        # --- L4: Escalation ---
        run_l4_escalation "$l2_result" "$l3_issues"
        save_state "l4_escalated"
    else
        save_state "l2_failing"
        log "INFO" "Waiting for threshold (${FAIL_COUNT}/${L3_FAIL_THRESHOLD}) before L3 diagnostic"
    fi

    exit 0  # Always exit 0 to not trigger launchd restart of watchdog itself
}

main "$@"
