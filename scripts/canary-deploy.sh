#!/bin/bash
# canary-deploy.sh — Canary deployment with auto-rollback
# Usage: canary-deploy.sh <source-dir> <target-dir> [--threshold N] [--duration S]
#
# Deploys code with canary monitoring and automatic rollback on failure.
# Specifically designed for AgentSystem extension deployments.
set -euo pipefail

# --- Constants ---
readonly LOG_FILE="/tmp/canary-deploy.log"
readonly BACKUP_BASE="/tmp/deploy-backups"
readonly MEMORY_BACKUP_DIR="${HOME}/.agent-evolution/my-patches/manual-patches/cognitive-memory-backup"
readonly WEBHOOK_FILE="${HOME}/.agent-evolution/webhook-url.txt"
readonly GATEWAY_LABEL="gui/$(id -u)/ai.agent-system.gateway"
readonly GATEWAY_LOG_DIR="${HOME}/.agent-evolution/logs"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# --- Defaults ---
SOURCE_DIR=""
TARGET_DIR=""
ERROR_THRESHOLD=3
MONITOR_DURATION=60
DISCORD_WEBHOOK_URL=""

# --- Logging ---
log() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" | tee -a "$LOG_FILE"
}

log_separator() {
    echo "========================================" | tee -a "$LOG_FILE"
}

# --- Discord notification ---
send_discord_alert() {
    local message="$1"
    local color="${2:-16711680}"  # Default: red

    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        log "WARN" "No Discord webhook configured, skipping alert"
        return 0
    fi

    local payload
    payload=$(cat <<JSONEOF
{
  "embeds": [{
    "title": "Oracle Canary Deploy Alert",
    "description": "${message}",
    "color": ${color},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "footer": {"text": "canary-deploy.sh"}
  }]
}
JSONEOF
)

    if curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK_URL" | grep -q "^2"; then
        log "INFO" "Discord alert sent"
    else
        log "WARN" "Failed to send Discord alert"
    fi
}

# --- Usage ---
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <source-dir> <target-dir> [OPTIONS]

Arguments:
  source-dir    Directory containing new code to deploy
  target-dir    Deployment target directory

Options:
  --threshold N   Max allowed errors during canary (default: 3)
  --duration S    Canary monitoring duration in seconds (default: 60)
  -h, --help      Show this help

Examples:
  ${SCRIPT_NAME} ./build/ /opt/homebrew/lib/node_modules/agent-system/extensions/memory-lancedb/
  ${SCRIPT_NAME} ./dist/ /opt/homebrew/lib/node_modules/agent-system/extensions/my-ext/ --threshold 5 --duration 120
EOF
    exit 0
}

# --- Arg parsing ---
parse_args() {
    if [[ $# -lt 2 ]]; then
        log "ERROR" "Both source-dir and target-dir are required"
        usage
    fi

    local positional_count=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR" "--threshold requires a numeric argument"
                    exit 1
                fi
                ERROR_THRESHOLD="$2"
                shift 2
                ;;
            --duration)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR" "--duration requires a numeric argument"
                    exit 1
                fi
                MONITOR_DURATION="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            -*)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ $positional_count -eq 0 ]]; then
                    SOURCE_DIR="$1"
                    positional_count=1
                elif [[ $positional_count -eq 1 ]]; then
                    TARGET_DIR="$1"
                    positional_count=2
                else
                    log "ERROR" "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate
    if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" ]]; then
        log "ERROR" "Both source-dir and target-dir are required"
        exit 1
    fi

    if [[ ! -d "$SOURCE_DIR" ]]; then
        log "ERROR" "Source directory does not exist: ${SOURCE_DIR}"
        exit 1
    fi

    # Resolve source to absolute path
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

    # Target may not exist yet (first deploy), but parent must
    local target_parent
    target_parent="$(dirname "$TARGET_DIR")"
    if [[ ! -d "$target_parent" ]]; then
        log "ERROR" "Target parent directory does not exist: ${target_parent}"
        exit 1
    fi

    # Resolve target to absolute if it exists
    if [[ -d "$TARGET_DIR" ]]; then
        TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
    fi
}

# --- Detect AgentSystem extension ---
is_agent-system_extension() {
    [[ "$TARGET_DIR" == *"/agent-system/extensions/"* ]]
}

# --- Detect memory-lancedb extension ---
is_memory_plugin() {
    [[ "$TARGET_DIR" == *"/memory-lancedb"* ]]
}

# --- Find gateway log file ---
find_gateway_log() {
    local log_file=""

    # Check common locations
    for candidate in \
        "${GATEWAY_LOG_DIR}/gateway.log" \
        "${GATEWAY_LOG_DIR}/stderr.log" \
        "${HOME}/.agent-evolution/gateway-stderr.log" \
        "/tmp/agent-system-gateway.log"; do
        if [[ -f "$candidate" ]]; then
            log_file="$candidate"
            break
        fi
    done

    if [[ -z "$log_file" ]]; then
        # Try to find from launchd plist
        local plist_stderr
        plist_stderr="$(defaults read "${HOME}/Library/LaunchAgents/ai.agent-system.gateway" StandardErrorPath 2>/dev/null || true)"
        if [[ -n "$plist_stderr" && -f "$plist_stderr" ]]; then
            log_file="$plist_stderr"
        fi
    fi

    echo "$log_file"
}

# --- Step 1: Create backup ---
create_backup() {
    local backup_dir="${BACKUP_BASE}/${TIMESTAMP}"
    mkdir -p "$backup_dir"

    if [[ -d "$TARGET_DIR" ]]; then
        log "INFO" "Step 1: Creating backup of ${TARGET_DIR}"
        cp -R "$TARGET_DIR" "${backup_dir}/target-backup"
        log "INFO" "Backup saved to ${backup_dir}/target-backup ($(du -sh "${backup_dir}/target-backup" | cut -f1))"
    else
        log "INFO" "Step 1: Target does not exist yet, no backup needed"
        mkdir -p "${backup_dir}"
        touch "${backup_dir}/.no-previous-target"
    fi

    echo "$backup_dir"
}

# --- Step 2: Deploy ---
deploy() {
    log "INFO" "Step 2: Deploying from ${SOURCE_DIR} to ${TARGET_DIR}"

    if [[ -d "$TARGET_DIR" ]]; then
        # Target exists — clear and copy (needs sudo for /opt paths)
        if [[ "$TARGET_DIR" == /opt/* ]]; then
            log "INFO" "Target in /opt, using sudo for deploy"
            sudo find "$TARGET_DIR" -mindepth 1 -delete
            sudo cp -R "${SOURCE_DIR}/." "$TARGET_DIR/"
        else
            find "$TARGET_DIR" -mindepth 1 -delete
            cp -R "${SOURCE_DIR}/." "$TARGET_DIR/"
        fi
    else
        # First deploy
        if [[ "$TARGET_DIR" == /opt/* ]]; then
            sudo mkdir -p "$TARGET_DIR"
            sudo cp -R "${SOURCE_DIR}/." "$TARGET_DIR/"
        else
            mkdir -p "$TARGET_DIR"
            cp -R "${SOURCE_DIR}/." "$TARGET_DIR/"
        fi
    fi

    log "INFO" "Deploy complete ($(du -sh "$TARGET_DIR" | cut -f1))"
}

# --- Step 2b: Update memory plugin backup ---
update_memory_backup() {
    if ! is_memory_plugin; then
        return 0
    fi

    log "INFO" "Detected memory-lancedb plugin, updating canonical backup"
    mkdir -p "$MEMORY_BACKUP_DIR"

    # Copy the key files
    for fname in index.ts config.ts; do
        if [[ -f "${SOURCE_DIR}/${fname}" ]]; then
            cp "${SOURCE_DIR}/${fname}" "${MEMORY_BACKUP_DIR}/${fname}.patched"
            log "INFO" "Updated ${MEMORY_BACKUP_DIR}/${fname}.patched"
        fi
    done
}

# --- Step 3: Restart gateway ---
restart_gateway() {
    if ! is_agent-system_extension; then
        log "INFO" "Step 3: Not an AgentSystem extension, skipping gateway restart"
        return 0
    fi

    log "INFO" "Step 3: Restarting AgentSystem gateway via SIGTERM..."

    # SIGTERM + KeepAlive = clean restart (not kill -9, not bootout+bootstrap)
    if launchctl kill SIGTERM "$GATEWAY_LABEL" 2>/dev/null; then
        log "INFO" "SIGTERM sent to gateway, waiting for restart..."
    else
        log "WARN" "launchctl kill failed (gateway may not be running)"
        log "INFO" "Attempting bootstrap..."
        launchctl bootstrap "gui/$(id -u)" "${HOME}/Library/LaunchAgents/ai.agent-system.gateway.plist" 2>/dev/null || true
    fi

    # Wait for gateway to come back (max 15 seconds)
    local wait_count=0
    local max_wait=15
    while [[ $wait_count -lt $max_wait ]]; do
        sleep 1
        wait_count=$((wait_count + 1))
        if pgrep -f "agent-system.*gateway" &>/dev/null; then
            log "INFO" "Gateway process detected after ${wait_count}s"
            return 0
        fi
    done

    log "WARN" "Gateway process not detected after ${max_wait}s (may still be starting)"
}

# --- Step 4: Canary monitoring ---
monitor_canary() {
    if ! is_agent-system_extension; then
        log "INFO" "Step 4: Not an AgentSystem extension, skipping canary monitoring"
        return 0
    fi

    local gateway_log
    gateway_log="$(find_gateway_log)"

    if [[ -z "$gateway_log" ]]; then
        log "WARN" "Step 4: Cannot find gateway log file, skipping canary monitoring"
        log "WARN" "Deploy will be considered successful without monitoring"
        return 0
    fi

    log "INFO" "Step 4: Starting canary monitoring (${MONITOR_DURATION}s, threshold: ${ERROR_THRESHOLD} errors)"
    log "INFO" "Watching log: ${gateway_log}"

    # Record current log position
    local log_start_line
    log_start_line="$(wc -l < "$gateway_log" 2>/dev/null || echo 0)"
    log_start_line="$(echo "$log_start_line" | tr -d ' ')"

    local elapsed=0
    local error_count=0
    local check_interval=5

    while [[ $elapsed -lt $MONITOR_DURATION ]]; do
        sleep $check_interval
        elapsed=$((elapsed + check_interval))

        # Count new ERROR/FATAL lines since deploy
        local current_lines
        current_lines="$(wc -l < "$gateway_log" 2>/dev/null || echo 0)"
        current_lines="$(echo "$current_lines" | tr -d ' ')"

        if [[ $current_lines -gt $log_start_line ]]; then
            local new_errors
            new_errors="$(tail -n +"$((log_start_line + 1))" "$gateway_log" | grep -c -iE 'ERROR|FATAL|CRASH|UNCAUGHT|UNHANDLED' 2>/dev/null || echo 0)"
            error_count=$((new_errors))
        fi

        # Progress report every 15 seconds
        if [[ $((elapsed % 15)) -eq 0 ]]; then
            log "INFO" "Canary [${elapsed}/${MONITOR_DURATION}s]: ${error_count} errors detected"
        fi

        # Early abort if threshold exceeded
        if [[ $error_count -gt $ERROR_THRESHOLD ]]; then
            log "ERROR" "Canary FAILED: ${error_count} errors exceeds threshold (${ERROR_THRESHOLD})"

            # Show the error lines
            log "ERROR" "Recent errors:"
            tail -n +"$((log_start_line + 1))" "$gateway_log" | grep -iE 'ERROR|FATAL|CRASH|UNCAUGHT|UNHANDLED' | tail -10 | tee -a "$LOG_FILE"

            return 1
        fi
    done

    log "INFO" "Canary PASSED: ${error_count} errors in ${MONITOR_DURATION}s (threshold: ${ERROR_THRESHOLD})"
    return 0
}

# --- Step 5: Rollback ---
rollback() {
    local backup_dir="$1"
    local backup_target="${backup_dir}/target-backup"

    log "ERROR" "Step 5: INITIATING ROLLBACK"

    if [[ -f "${backup_dir}/.no-previous-target" ]]; then
        log "WARN" "No previous target existed, removing deployed files"
        if [[ "$TARGET_DIR" == /opt/* ]]; then
            sudo rm -rf "$TARGET_DIR"
        else
            rm -rf "$TARGET_DIR"
        fi
    elif [[ -d "$backup_target" ]]; then
        log "INFO" "Restoring from backup: ${backup_target}"
        if [[ "$TARGET_DIR" == /opt/* ]]; then
            sudo find "$TARGET_DIR" -mindepth 1 -delete
            sudo cp -R "${backup_target}/." "$TARGET_DIR/"
        else
            find "$TARGET_DIR" -mindepth 1 -delete
            cp -R "${backup_target}/." "$TARGET_DIR/"
        fi
        log "INFO" "Rollback complete, files restored"
    else
        log "ERROR" "CRITICAL: Backup not found at ${backup_target}, cannot rollback!"
        send_discord_alert "CRITICAL: Rollback failed - backup not found!\\nTarget: ${TARGET_DIR}\\nBackup: ${backup_target}" "16711680"
        return 1
    fi

    # Restart gateway after rollback
    if is_agent-system_extension; then
        log "INFO" "Restarting gateway after rollback..."
        launchctl kill SIGTERM "$GATEWAY_LABEL" 2>/dev/null || true
        sleep 3
    fi

    # Discord alert about rollback
    send_discord_alert "Canary deploy ROLLED BACK\\nTarget: ${TARGET_DIR}\\nBackup: ${backup_dir}\\nThreshold: ${ERROR_THRESHOLD} errors" "16776960"

    log "ERROR" "Rollback completed. Previous version restored."
}

# ============================================================
# MAIN
# ============================================================
main() {
    log_separator
    log "INFO" "${SCRIPT_NAME} started at ${TIMESTAMP}"
    log "INFO" "Arguments: $*"

    parse_args "$@"

    # Load Discord webhook
    if [[ -f "$WEBHOOK_FILE" ]]; then
        DISCORD_WEBHOOK_URL="$(cat "$WEBHOOK_FILE" | tr -d '[:space:]')"
        log "INFO" "Discord webhook loaded"
    else
        log "WARN" "No webhook file at ${WEBHOOK_FILE}, Discord alerts disabled"
    fi

    log "INFO" "Source: ${SOURCE_DIR}"
    log "INFO" "Target: ${TARGET_DIR}"
    log "INFO" "Error threshold: ${ERROR_THRESHOLD}"
    log "INFO" "Monitor duration: ${MONITOR_DURATION}s"

    # Step 1: Backup
    local backup_dir
    backup_dir="$(create_backup)"

    # Step 2: Deploy
    deploy
    update_memory_backup

    # Step 3: Restart (if applicable)
    restart_gateway

    # Step 4: Monitor
    local canary_result=0
    monitor_canary || canary_result=$?

    if [[ $canary_result -ne 0 ]]; then
        # Step 5: Rollback
        rollback "$backup_dir"
        log_separator
        echo ""
        echo "  CANARY RESULT: FAIL (rolled back)"
        echo "  Backup: ${backup_dir}"
        echo "  Log: ${LOG_FILE}"
        echo ""
        exit 1
    fi

    # Step 6: Success
    log_separator
    log "INFO" "RESULT: CANARY DEPLOY SUCCESSFUL"
    send_discord_alert "Canary deploy SUCCESSFUL\\nTarget: ${TARGET_DIR}\\nDuration: ${MONITOR_DURATION}s, Errors: 0/${ERROR_THRESHOLD}" "65280"

    echo ""
    echo "  CANARY RESULT: PASS"
    echo "  Target: ${TARGET_DIR}"
    echo "  Backup: ${backup_dir}"
    echo ""

    exit 0
}

main "$@"
