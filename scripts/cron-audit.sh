#!/usr/bin/env bash
# cron-audit.sh — Cron job audit: crontab + AgentSystem internal
# Tum cron job'larin durumunu raporlar, basarisizlari Discord'a bildirir.
#
# Kullanim:
#   cron-audit.sh              # Tam rapor
#   cron-audit.sh --quiet      # Sadece ozet
#   cron-audit.sh --help       # Yardim

set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

# --- Constants ---
JOBS_JSON="$HOME/.agent-system/cron/jobs.json"
WEBHOOK_FILE="$HOME/.agent-system/webhook-url.txt"
CONSECUTIVE_ERROR_THRESHOLD=3
TMPDIR_AUDIT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters (file-backed to survive subshells) ---
COUNTER_FILE="$TMPDIR_AUDIT/counters"
echo "0 0 0 0" > "$COUNTER_FILE"

add_counter() {
    # Usage: add_counter healthy|failing|disabled
    local kind="$1"
    read -r total healthy failing disabled < "$COUNTER_FILE"
    total=$((total + 1))
    case "$kind" in
        healthy)  healthy=$((healthy + 1)) ;;
        failing)  failing=$((failing + 1)) ;;
        disabled) disabled=$((disabled + 1)) ;;
    esac
    echo "$total $healthy $failing $disabled" > "$COUNTER_FILE"
}

read_counters() {
    read -r TOTAL HEALTHY FAILING DISABLED < "$COUNTER_FILE"
}

# Discord alert accumulator (file-backed)
DISCORD_FILE="$TMPDIR_AUDIT/discord_alerts"
touch "$DISCORD_FILE"

# --- Functions ---
usage() {
    cat <<'USAGE'
cron-audit.sh — Cron job audit (crontab + AgentSystem internal)

Usage:
    cron-audit.sh              Full audit report
    cron-audit.sh --quiet      Summary only (no tables)
    cron-audit.sh --help       Show this help

Output:
    Part A: System crontab jobs with log file freshness
    Part B: AgentSystem internal cron jobs from jobs.json
    Summary: healthy / failing / disabled counts
    Discord: webhook alert if any job has >= 3 consecutive errors
USAGE
    exit 0
}

# Parse args
QUIET=false
case "${1:-}" in
    --help|-h) usage ;;
    --quiet|-q) QUIET=true ;;
esac

# --- Part A: System Crontab ---
audit_crontab_jobs() {
    local print_table="$1"

    if [[ "$print_table" == true ]]; then
        echo -e "\n${CYAN}${BOLD}=== CRONTAB JOBS ===${NC}"
        printf "  ${DIM}%-44s | %-13s | %s${NC}\n" "Command" "Schedule" "Log Status"
        printf "  ${DIM}%-44s-+-%-13s-+-%s${NC}\n" \
            "--------------------------------------------" "-------------" "-------------------"
    fi

    local has_jobs=false

    while IFS= read -r line; do
        # Skip empty, comments, env assignments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        [[ "$line" =~ ^[A-Z_]+= ]] && continue

        has_jobs=true

        # Parse cron fields
        local schedule command log_file
        schedule=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
        command=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

        # Extract log file from >> redirect
        log_file=""
        if [[ "$command" =~ \>\>\ *([^ ]+) ]]; then
            log_file="${BASH_REMATCH[1]}"
        fi

        # Display name: script basename
        local display_name
        display_name=$(echo "$command" | awk '{print $1}' | xargs basename 2>/dev/null || echo "$command")

        # Check log status
        local log_status color
        if [[ -z "$log_file" ]]; then
            log_status="no log redirect"
            color="$YELLOW"
            add_counter healthy
        elif [[ ! -f "$log_file" ]]; then
            log_status="log not found"
            color="$YELLOW"
            add_counter healthy
        else
            local mod_epoch now_epoch age_hours
            mod_epoch=$(stat -f '%m' "$log_file" 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age_hours=$(( (now_epoch - mod_epoch) / 3600 ))

            if [[ $age_hours -le 24 ]]; then
                log_status="updated ${age_hours}h ago"
                color="$GREEN"
                add_counter healthy
            elif [[ $age_hours -le 72 ]]; then
                log_status="stale (${age_hours}h)"
                color="$YELLOW"
                add_counter healthy
            else
                log_status="STALE (${age_hours}h)"
                color="$RED"
                add_counter failing
            fi
        fi

        if [[ "$print_table" == true ]]; then
            # Truncate if needed
            if [[ ${#display_name} -gt 44 ]]; then
                display_name="${display_name:0:41}..."
            fi
            printf "  %-44s | %-13s | ${color}%s${NC}\n" "$display_name" "$schedule" "$log_status"
        fi

    done < <(crontab -l 2>/dev/null || true)

    if [[ "$print_table" == true ]] && [[ "$has_jobs" == false ]]; then
        echo -e "  ${DIM}(crontab bos)${NC}"
    fi
}

# --- Part B: AgentSystem Internal Cron Jobs ---
audit_agent-system_jobs() {
    local print_table="$1"

    if [[ "$print_table" == true ]]; then
        echo -e "\n${CYAN}${BOLD}=== OPENCLAW CRON JOBS ===${NC}"
    fi

    if [[ ! -f "$JOBS_JSON" ]]; then
        if [[ "$print_table" == true ]]; then
            echo -e "  ${YELLOW}jobs.json bulunamadi: $JOBS_JSON${NC}"
        fi
        return
    fi

    if [[ "$print_table" == true ]]; then
        printf "  ${DIM}%-30s | %-18s | %-9s | %-6s | %s${NC}\n" \
            "Name" "Agent" "Status" "Errors" "Last Error"
        printf "  ${DIM}%-30s-+-%-18s-+-%-9s-+-%-6s-+-%s${NC}\n" \
            "------------------------------" "------------------" "---------" "------" "-----------------------------"
    fi

    # Single python3 call: parse jobs.json, output TSV
    local parsed_file="$TMPDIR_AUDIT/agent-system_parsed.tsv"
    python3 - "$JOBS_JSON" > "$parsed_file" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

jobs = data.get("jobs", data) if isinstance(data, dict) else data

for job in jobs:
    name = job.get("name", "?")
    agent_id = job.get("agentId", "?")
    enabled = job.get("enabled", True)
    state = job.get("state", {})
    last_status = state.get("lastStatus", "?")
    consecutive_errors = state.get("consecutiveErrors", 0)
    last_error = state.get("lastError", "")

    # Truncate last_error for display
    if len(last_error) > 40:
        last_error = last_error[:37] + "..."

    # Replace tabs/newlines in last_error to keep TSV clean
    last_error = last_error.replace("\t", " ").replace("\n", " ")

    print(f"{name}\t{agent_id}\t{enabled}\t{last_status}\t{consecutive_errors}\t{last_error}")
PYEOF

    # Process parsed output
    while IFS=$'\t' read -r name agent_id enabled last_status consecutive_errors last_error; do
        local color status_display

        if [[ "$enabled" == "False" ]]; then
            color="$DIM"
            status_display="disabled"
            add_counter disabled
        elif [[ "$consecutive_errors" -ge "$CONSECUTIVE_ERROR_THRESHOLD" ]]; then
            color="$RED"
            status_display="$last_status"
            add_counter failing
            # Accumulate for Discord alert
            echo "${name} (${agent_id}): ${consecutive_errors} errors -- ${last_error}" >> "$DISCORD_FILE"
        elif [[ "$consecutive_errors" -gt 0 ]]; then
            color="$YELLOW"
            status_display="$last_status"
            add_counter failing
        else
            color="$GREEN"
            status_display="$last_status"
            add_counter healthy
        fi

        if [[ "$print_table" == true ]]; then
            # Truncate name/agent if needed
            local display_name="$name"
            if [[ ${#display_name} -gt 30 ]]; then
                display_name="${display_name:0:27}..."
            fi
            local display_agent="$agent_id"
            if [[ ${#display_agent} -gt 18 ]]; then
                display_agent="${display_agent:0:15}..."
            fi

            printf "  ${color}%-30s | %-18s | %-9s | %-6s | %s${NC}\n" \
                "$display_name" "$display_agent" "$status_display" "$consecutive_errors" "$last_error"
        fi

    done < "$parsed_file"
}

# --- Discord Alert ---
send_discord_alert() {
    if [[ ! -s "$DISCORD_FILE" ]]; then
        return
    fi

    if [[ ! -f "$WEBHOOK_FILE" ]]; then
        echo -e "\n  ${YELLOW}Discord webhook dosyasi bulunamadi: $WEBHOOK_FILE${NC}"
        return
    fi

    local webhook_url
    webhook_url=$(head -1 "$WEBHOOK_FILE" | tr -d '[:space:]')

    if [[ -z "$webhook_url" ]]; then
        echo -e "\n  ${YELLOW}Discord webhook URL bos${NC}"
        return
    fi

    # Build payload safely with python3 (reads alert lines from file)
    local payload
    payload=$(python3 - "$DISCORD_FILE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    lines = f.read().strip()

# Limit to 10 lines for Discord embed
desc_lines = lines.split("\n")[:10]
description = "\n".join(desc_lines)

embed = {
    "title": "Cron Job Alert",
    "description": description,
    "color": 16711680,
    "footer": {"text": "cron-audit"}
}
print(json.dumps({"embeds": [embed]}))
PYEOF
)

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$webhook_url" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        echo -e "  ${GREEN}Discord alert gonderildi${NC}"
    else
        echo -e "  ${RED}Discord alert gonderilemedi (HTTP $http_code)${NC}"
    fi
}

# --- Summary ---
print_summary() {
    read_counters
    echo -e "\n${CYAN}${BOLD}=== OZET ===${NC}"
    echo -e "  ${GREEN}${HEALTHY} healthy${NC}, ${RED}${FAILING} failing${NC}, ${DIM}${DISABLED} disabled${NC} / ${BOLD}${TOTAL} total${NC} jobs"
}

# --- Main ---
main() {
    echo -e "${BOLD}Oracle Cron Audit — $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    local show_table=true
    if [[ "$QUIET" == true ]]; then
        show_table=false
    fi

    audit_crontab_jobs "$show_table"
    audit_agent-system_jobs "$show_table"
    print_summary
    send_discord_alert
}

main
