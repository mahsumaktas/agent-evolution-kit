#!/usr/bin/env bash
# Oracle Daily System Check
# Her gun 03:00'te calisir. Hizli sistem kontrolu yapar.
# Kritik sorun varsa log'a yazar.

set -euo pipefail

SCRIPTS_DIR="$HOME/clawd/scripts"
LOG_FILE="$HOME/clawd/memory/bridge-logs/daily-check-$(date +%Y%m%d).log"

{
    echo "=== Oracle Daily Check — $(date) ==="
    bash "$SCRIPTS_DIR/system-check.sh" --quick 2>&1 || true
    echo ""
    echo "=== Check tamamlandi — $(date) ==="
} > "$LOG_FILE" 2>&1

# Disk kritik mi kontrol et
DISK_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
if [[ $DISK_PCT -ge 90 ]]; then
    echo "KRITIK: Disk kullanimi ${DISK_PCT}%" >> "$LOG_FILE"
fi

# Blackboard: system health status
BLACKBOARD="$HOME/clawd/scripts/blackboard.sh"
if [[ $DISK_PCT -ge 90 ]]; then
    bash "$BLACKBOARD" set "system:health_status" "FAIL" 2>/dev/null || true
elif [[ $DISK_PCT -ge 80 ]]; then
    bash "$BLACKBOARD" set "system:health_status" "WARN" 2>/dev/null || true
else
    bash "$BLACKBOARD" set "system:health_status" "OK" 2>/dev/null || true
fi
