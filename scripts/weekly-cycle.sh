#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# weekly-cycle.sh — Weekly self-evolution automation orchestrator
#
# Runs the full weekly cycle: system check, autonomous research,
# predictive analysis, prompt evolution review, and memory cleanup.
# Each step is error-tolerant — a failure does not stop the cycle.
#
# Usage:
#   weekly-cycle.sh              Run full weekly cycle
#   weekly-cycle.sh --dry-run    Show what would run without executing

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
SCRIPTS_DIR="$AEK_HOME/scripts"
LOG_DIR="$AEK_HOME/memory/bridge-logs"
CYCLE_LOG="$AEK_HOME/memory/evolution-log.md"

# === Colors ===
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[weekly]${NC} $(date +%H:%M:%S) $1" >&2; }
err() { echo -e "${RED}[weekly]${NC} $(date +%H:%M:%S) $1" >&2; }
step() { echo -e "${CYAN}[weekly]${NC} === $1 ===" >&2; }

# === Parse Arguments ===
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    echo "Usage: weekly-cycle.sh [--dry-run]"
    echo ""
    echo "Steps:"
    echo "  1. System check (system-check.sh --quick)"
    echo "  2. Autonomous research (research.sh --auto)"
    echo "  3. Predictive analysis (predict.sh --weekly)"
    echo "  4. Prompt evolution review"
    echo "  5. Memory cleanup"
    echo "  6. Log cycle to evolution log"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show commands without executing"
    exit 0
}

TIMESTAMP=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$CYCLE_LOG")"

step "WEEKLY EVOLUTION CYCLE — $TIMESTAMP"

# === Step 1: System Check ===
step "1/5 SYSTEM CHECK"
if $DRY_RUN; then
    log "[DRY] system-check.sh --quick"
else
    bash "$SCRIPTS_DIR/system-check.sh" --quick 2>&1 | while read -r line; do
        log "$line"
    done || err "System check failed (continuing)"
fi

# === Step 2: Autonomous Research ===
step "2/5 AUTONOMOUS RESEARCH"
if $DRY_RUN; then
    log "[DRY] research.sh --auto"
else
    bash "$SCRIPTS_DIR/research.sh" --auto 2>&1 | while read -r line; do
        log "$line"
    done || err "Research failed (continuing)"
fi

# === Step 3: Predictive Analysis ===
step "3/5 PREDICTIVE ANALYSIS"
if $DRY_RUN; then
    log "[DRY] predict.sh --weekly"
else
    bash "$SCRIPTS_DIR/predict.sh" --weekly 2>&1 | while read -r line; do
        log "$line"
    done || err "Prediction failed (continuing)"
fi

# === Step 4: Memory Cleanup ===
step "4/5 MEMORY CLEANUP"
if $DRY_RUN; then
    log "[DRY] Cleanup: old bridge logs, old predictions, old briefings"
else
    # Clean old bridge logs (>60 days)
    local_cleaned=0
    while IFS= read -r f; do
        rm -f "$f"
        local_cleaned=$((local_cleaned + 1))
    done < <(find "$LOG_DIR" -name "*.json" -mtime +60 2>/dev/null)
    [[ $local_cleaned -gt 0 ]] && log "Cleaned $local_cleaned old bridge logs"

    # Clean old predictions (>90 days)
    local_cleaned=0
    while IFS= read -r f; do
        rm -f "$f"
        local_cleaned=$((local_cleaned + 1))
    done < <(find "$AEK_HOME/memory/predictions" -name "*.md" -mtime +90 2>/dev/null)
    [[ $local_cleaned -gt 0 ]] && log "Cleaned $local_cleaned old predictions"

    # Clean old briefings (>60 days)
    local_cleaned=0
    while IFS= read -r f; do
        rm -f "$f"
        local_cleaned=$((local_cleaned + 1))
    done < <(find "$AEK_HOME/memory/briefings" -name "*.md" -mtime +60 2>/dev/null)
    [[ $local_cleaned -gt 0 ]] && log "Cleaned $local_cleaned old briefings"

    # Trim watchdog log
    local watchdog_log="$AEK_HOME/memory/logs/watchdog.log"
    if [[ -f "$watchdog_log" ]]; then
        local wl_lines
        wl_lines=$(wc -l < "$watchdog_log" | tr -d ' ')
        if [[ $wl_lines -gt 5000 ]]; then
            tail -2500 "$watchdog_log" > "${watchdog_log}.tmp"
            mv "${watchdog_log}.tmp" "$watchdog_log"
            log "Trimmed watchdog log from $wl_lines to 2500 lines"
        fi
    fi

    log "Memory cleanup completed"
fi

# === Step 5: Log Cycle ===
step "5/5 CYCLE LOG"
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

CYCLE_ENTRY="
## $TIMESTAMP — Weekly Evolution Cycle
- **Duration:** ${DURATION}s
- **System Check:** completed
- **Research:** auto mode
- **Prediction:** weekly mode
- **Memory Cleanup:** completed
- **Status:** COMPLETED"

if $DRY_RUN; then
    log "[DRY] Would write to evolution log:"
    echo "$CYCLE_ENTRY"
else
    echo "$CYCLE_ENTRY" >> "$CYCLE_LOG"
    log "Evolution log updated"
fi

log "Weekly cycle completed: ${DURATION}s"
