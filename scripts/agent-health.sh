#!/usr/bin/env bash
# agent-health.sh — AgentSystem agent saglik raporu
# Her agent icin aktiflik durumu, session sayisi ve boyutu raporlar.
#
# Kullanim:
#   agent-health.sh           # Tum agentlarin durumunu goster

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config ---
AGENTS_DIR="$HOME/.agent-system/agents"
DB="$HOME/clawd/memory/metrics.db"
WATCHDOG_LOG="/tmp/watchdog.log"
WATCHDOG_STATE="/tmp/watchdog-state.json"
CRASH_INSIGHTS_FILE="$HOME/clawd/memory/crash-insights.json"
DORMANT_THRESHOLD=$((48 * 3600))  # 48 saat (saniye)
NOW=$(date +%s)
SEVEN_DAYS_AGO=$((NOW - 7 * 86400))

# --- Pre-checks ---
if [[ ! -d "$AGENTS_DIR" ]]; then
    echo -e "${RED}HATA:${NC} $AGENTS_DIR bulunamadi."
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo -e "${YELLOW}UYARI:${NC} sqlite3 bulunamadi, metrikler yazilmayacak."
    NO_SQLITE=1
fi

# --- Header ---
echo -e "\n${CYAN}${BOLD}=== OPENCLAW AGENT HEALTH ===${NC}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

printf "${BOLD}%-20s %-10s %8s %16s %8s${NC}\n" "AGENT" "STATUS" "SESSIONS" "LAST ACTIVITY" "SIZE"
printf "%-20s %-10s %8s %16s %8s\n" "--------------------" "----------" "--------" "----------------" "--------"

# --- Counters ---
active=0
dormant=0
dead=0
total=0

# --- Scan agents ---
for agent_dir in "$AGENTS_DIR"/*/; do
    [[ ! -d "$agent_dir" ]] && continue

    agent_name=$(basename "$agent_dir")
    sessions_dir="$agent_dir/sessions"
    total=$((total + 1))

    # Session sayisi ve son aktivite
    session_count=0
    last_mtime=0
    size_str="-"

    if [[ -d "$sessions_dir" ]]; then
        # Sadece aktif .jsonl dosyalari (deleted olanlari haric tut)
        while IFS= read -r -d '' f; do
            session_count=$((session_count + 1))
            mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$last_mtime" ]]; then
                last_mtime=$mtime
            fi
        done < <(find "$sessions_dir" -maxdepth 1 -name '*.jsonl' ! -name '*.deleted.*' -print0 2>/dev/null)

        # Toplam boyut
        if [[ $session_count -gt 0 ]]; then
            size_str=$(du -sh "$sessions_dir" 2>/dev/null | awk '{print $1}')
        fi
    fi

    # Durum belirle
    if [[ $session_count -eq 0 && $last_mtime -eq 0 ]]; then
        status="DEAD"
        status_color="$RED"
        dead=$((dead + 1))
        last_activity="-"
    else
        age=$((NOW - last_mtime))
        last_activity=$(date -r "$last_mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")

        if [[ $age -gt $DORMANT_THRESHOLD ]]; then
            status="DORMANT"
            status_color="$YELLOW"
            dormant=$((dormant + 1))
        else
            status="ACTIVE"
            status_color="$GREEN"
            active=$((active + 1))
        fi
    fi

    printf "%-20s ${status_color}%-10s${NC} %8d %16s %8s\n" \
        "$agent_name" "$status" "$session_count" "$last_activity" "$size_str"
done

# --- Summary ---
echo ""
printf "%-20s %-10s %8s %16s %8s\n" "--------------------" "----------" "--------" "----------------" "--------"
echo -e "${BOLD}${GREEN}$active active${NC}, ${YELLOW}$dormant dormant${NC}, ${RED}$dead dead${NC} — toplam $total agent"
echo ""

# --- Metrics ---
if [[ -z "${NO_SQLITE:-}" ]] && [[ -f "$DB" ]]; then
    sqlite3 "$DB" "INSERT INTO metrics (agent,metric,value,tags,ts) VALUES ('agent-health','agents_active',$active,'',strftime('%Y-%m-%dT%H:%M:%S','now','localtime'));"
    sqlite3 "$DB" "INSERT INTO metrics (agent,metric,value,tags,ts) VALUES ('agent-health','agents_dormant',$dormant,'',strftime('%Y-%m-%dT%H:%M:%S','now','localtime'));"
    sqlite3 "$DB" "INSERT INTO metrics (agent,metric,value,tags,ts) VALUES ('agent-health','agents_dead',$dead,'',strftime('%Y-%m-%dT%H:%M:%S','now','localtime'));"
    echo -e "${CYAN}Metrikler yazildi: $DB${NC}"
fi

# ============================================================
# CRASH INSIGHTS
# ============================================================

# --- Crash categorization ---
categorize_crashes() {
    local log_file="$1"
    local oom=0 segfault=0 timeout=0 config_error=0 generic=0

    if [[ ! -f "$log_file" ]]; then
        echo "0:0:0:0:0"
        return
    fi

    # Read last 100 lines, categorize by pattern
    local last_lines
    last_lines="$(tail -100 "$log_file" 2>/dev/null || true)"

    if [[ -z "$last_lines" ]]; then
        echo "0:0:0:0:0"
        return
    fi

    oom=$(echo "$last_lines" | grep -ciE 'Killed|Cannot allocate|out of memory' 2>/dev/null || echo 0)
    segfault=$(echo "$last_lines" | grep -ciE 'SIGSEGV|segmentation fault' 2>/dev/null || echo 0)
    timeout=$(echo "$last_lines" | grep -ciE 'SIGALRM|timed out|exceeded.*duration' 2>/dev/null || echo 0)
    config_error=$(echo "$last_lines" | grep -ciE 'ENOENT|permission denied|not found' 2>/dev/null || echo 0)

    # Generic: ERROR lines that don't match above categories
    local total_errors
    total_errors=$(echo "$last_lines" | grep -ciE 'ERROR|FATAL|CRASH|UNCAUGHT' 2>/dev/null || echo 0)
    generic=$((total_errors - oom - segfault - timeout - config_error))
    if [[ $generic -lt 0 ]]; then generic=0; fi

    echo "${oom}:${segfault}:${timeout}:${config_error}:${generic}"
}

# --- Count recent crashes (last 7 days) ---
count_recent_crashes() {
    local log_file="$1"
    if [[ ! -f "$log_file" ]]; then
        echo 0
        return
    fi

    # Count ERROR/CRASH/FATAL lines with timestamps in last 7 days
    local count=0
    local seven_days_ago_str
    seven_days_ago_str="$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || echo "2026-02-22")"

    count=$(grep -cE "^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}" "$log_file" 2>/dev/null | head -1 || echo 0)
    # Simplified: count ERROR/CRASH in recent lines
    count=$(tail -500 "$log_file" 2>/dev/null | grep -cE '\[(ERROR|FATAL)\].*([Cc]rash|restart.*failed|force.restart)' 2>/dev/null || echo 0)
    echo "$count"
}

# --- Health score calculation ---
calculate_health_score() {
    local recent_crashes="$1"
    local consecutive_fails="$2"
    local avg_restart_time="$3"  # seconds, 0 if unknown
    local circuit_breaker_open="$4"  # 0 or 1

    local score=100

    # -20 per recent crash (7d)
    local crash_penalty=$((recent_crashes * 20))
    score=$((score - crash_penalty))

    # -15 if avg restart time > 30s
    if [[ $avg_restart_time -gt 30 ]]; then
        score=$((score - 15))
    fi

    # -10 per consecutive failure
    local fail_penalty=$((consecutive_fails * 10))
    score=$((score - fail_penalty))

    # -25 if circuit breaker is open
    if [[ $circuit_breaker_open -eq 1 ]]; then
        score=$((score - 25))
    fi

    # Clamp to [0, 100]
    if [[ $score -lt 0 ]]; then score=0; fi
    if [[ $score -gt 100 ]]; then score=100; fi

    echo "$score"
}

# --- Determine trend ---
determine_trend() {
    local current_score="$1"
    local previous_score="$2"

    if [[ $previous_score -eq -1 ]]; then
        echo "new"
        return
    fi

    local diff=$((current_score - previous_score))
    if [[ $diff -gt 10 ]]; then
        echo "improving"
    elif [[ $diff -lt -10 ]]; then
        echo "degrading"
    else
        echo "stable"
    fi
}

# --- Read watchdog state ---
get_watchdog_state() {
    local field="$1"
    local default_val="${2:-0}"
    if [[ -f "$WATCHDOG_STATE" ]]; then
        python3 -c "
import json
try:
    s = json.load(open('${WATCHDOG_STATE}'))
    print(s.get('${field}', ${default_val}))
except: print(${default_val})
" 2>/dev/null || echo "$default_val"
    else
        echo "$default_val"
    fi
}

# --- Read previous insights ---
get_previous_score() {
    local agent_key="$1"
    if [[ -f "$CRASH_INSIGHTS_FILE" ]]; then
        python3 -c "
import json
try:
    d = json.load(open('${CRASH_INSIGHTS_FILE}'))
    print(d.get('agents', {}).get('${agent_key}', {}).get('health_score', -1))
except: print(-1)
" 2>/dev/null || echo "-1"
    else
        echo "-1"
    fi
}

# --- Build crash insights ---
echo -e "\n${CYAN}${BOLD}=== CRASH INSIGHTS ===${NC}"

# Gateway crash analysis
gw_categories="$(categorize_crashes "$WATCHDOG_LOG")"
IFS=':' read -r gw_oom gw_segfault gw_timeout gw_config gw_generic <<< "$gw_categories"

gw_recent_crashes="$(count_recent_crashes "$WATCHDOG_LOG")"
gw_consecutive_fails="$(get_watchdog_state "fail_count" "0")"
gw_total_restarts="$(get_watchdog_state "total_restarts" "0")"

# Check circuit breaker state (from blackboard if available)
gw_circuit_open=0
if [[ -x "$HOME/clawd/scripts/blackboard.sh" ]]; then
    local_cb_state="$(bash "$HOME/clawd/scripts/blackboard.sh" get "circuit_breaker:gateway" 2>/dev/null || echo "")"
    if [[ "$local_cb_state" == "open" ]]; then
        gw_circuit_open=1
    fi
fi

# Estimate avg restart time (rough: if total_restarts > 0 and we know uptime)
gw_avg_restart=0

gw_prev_score="$(get_previous_score "gateway")"
gw_score="$(calculate_health_score "$gw_recent_crashes" "$gw_consecutive_fails" "$gw_avg_restart" "$gw_circuit_open")"
gw_trend="$(determine_trend "$gw_score" "$gw_prev_score")"

# Build categories map for gateway
gw_cat_json="{}"
if [[ $((gw_oom + gw_segfault + gw_timeout + gw_config + gw_generic)) -gt 0 ]]; then
    gw_cat_json="$(python3 -c "
import json
cats = {}
if ${gw_oom} > 0: cats['oom'] = ${gw_oom}
if ${gw_segfault} > 0: cats['segfault'] = ${gw_segfault}
if ${gw_timeout} > 0: cats['timeout'] = ${gw_timeout}
if ${gw_config} > 0: cats['config_error'] = ${gw_config}
if ${gw_generic} > 0: cats['generic'] = ${gw_generic}
print(json.dumps(cats))
" 2>/dev/null || echo "{}")"
fi

echo -e "\n${BOLD}Gateway:${NC}"
echo -e "  Health Score: ${gw_score}/100 (trend: ${gw_trend})"
echo -e "  Recent crashes (7d): ${gw_recent_crashes}"
echo -e "  Consecutive failures: ${gw_consecutive_fails}"
echo -e "  Total restarts: ${gw_total_restarts}"
echo -e "  Categories — OOM:${gw_oom} Segfault:${gw_segfault} Timeout:${gw_timeout} Config:${gw_config} Generic:${gw_generic}"

# --- HEALTH SCORES section ---
echo -e "\n${CYAN}${BOLD}=== HEALTH SCORES ===${NC}\n"

# Color based on score
score_color="$GREEN"
if [[ $gw_score -lt 50 ]]; then
    score_color="$RED"
elif [[ $gw_score -lt 75 ]]; then
    score_color="$YELLOW"
fi

printf "${BOLD}%-20s ${score_color}%3d/100${NC}  %-12s  %s${NC}\n" \
    "gateway" "$gw_score" "$gw_trend" "restarts:${gw_total_restarts} fails:${gw_consecutive_fails}"

# Add per-agent scores for all agents (simplified: based on session activity)
for agent_dir in "$AGENTS_DIR"/*/; do
    [[ ! -d "$agent_dir" ]] && continue
    local_agent_name=$(basename "$agent_dir")
    [[ "$local_agent_name" == "gateway" ]] && continue  # Already reported

    # Simple score: 100 if active, 60 if dormant, 20 if dead
    local_sessions_dir="$agent_dir/sessions"
    local_agent_score=100
    local_agent_trend="stable"

    if [[ -d "$local_sessions_dir" ]]; then
        local_last_mtime=0
        while IFS= read -r -d '' f; do
            local_mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
            if [[ "$local_mtime" -gt "$local_last_mtime" ]]; then
                local_last_mtime=$local_mtime
            fi
        done < <(find "$local_sessions_dir" -maxdepth 1 -name '*.jsonl' ! -name '*.deleted.*' -print0 2>/dev/null)

        if [[ $local_last_mtime -eq 0 ]]; then
            local_agent_score=20
        else
            local_age=$((NOW - local_last_mtime))
            if [[ $local_age -gt $DORMANT_THRESHOLD ]]; then
                local_agent_score=60
            fi
        fi
    else
        local_agent_score=20
    fi

    local_prev="$(get_previous_score "$local_agent_name")"
    local_agent_trend="$(determine_trend "$local_agent_score" "$local_prev")"

    local_sc="$GREEN"
    if [[ $local_agent_score -lt 50 ]]; then
        local_sc="$RED"
    elif [[ $local_agent_score -lt 75 ]]; then
        local_sc="$YELLOW"
    fi

    printf "${BOLD}%-20s ${local_sc}%3d/100${NC}  %-12s${NC}\n" \
        "$local_agent_name" "$local_agent_score" "$local_agent_trend"
done

echo ""

# --- Persist crash insights to JSON ---
python3 - "$CRASH_INSIGHTS_FILE" "$gw_score" "$gw_cat_json" "$gw_trend" "$gw_recent_crashes" "$gw_consecutive_fails" "$gw_total_restarts" <<'PYEOF'
import json, sys, os
from datetime import datetime

insights_path = sys.argv[1]
gw_score = int(sys.argv[2])
gw_cats = json.loads(sys.argv[3])
gw_trend = sys.argv[4]
gw_recent = int(sys.argv[5])
gw_consec = int(sys.argv[6])
gw_restarts = int(sys.argv[7])

# Load existing or create new
data = {}
if os.path.exists(insights_path):
    try:
        with open(insights_path) as f:
            data = json.load(f)
    except:
        data = {}

data["last_updated"] = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
if "agents" not in data:
    data["agents"] = {}

data["agents"]["gateway"] = {
    "health_score": gw_score,
    "crash_categories": gw_cats,
    "trend": gw_trend,
    "recent_crashes_7d": gw_recent,
    "consecutive_failures": gw_consec,
    "total_restarts": gw_restarts
}

os.makedirs(os.path.dirname(insights_path), exist_ok=True)
with open(insights_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

echo -e "${CYAN}Crash insights yazildi: $CRASH_INSIGHTS_FILE${NC}"
