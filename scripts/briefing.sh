#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# briefing.sh — Tri-phase daily status reporting system
#
# Generates morning, midday, and evening briefings with system health,
# goal progress, and metrics summaries.
#
# Usage:
#   briefing.sh morning              # Morning briefing (system health + goals)
#   briefing.sh midday               # Midday check-in (progress + blockers)
#   briefing.sh evening              # Evening review (daily summary)
#   briefing.sh custom <topic>       # On-demand topic briefing

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
MEMORY_DIR="$AEK_HOME/memory"
BRIEFING_DIR="$MEMORY_DIR/briefings"
GOALS_FILE="$MEMORY_DIR/goals/active-goals.json"
METRICS_DB="$MEMORY_DIR/metrics.db"
BRIDGE_SCRIPT="$AEK_HOME/scripts/bridge.sh"
LOG="$AEK_HOME/memory/logs/briefing.log"

TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H:%M')

# === Helpers ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

ensure_dirs() {
    mkdir -p "$BRIEFING_DIR"
    mkdir -p "$MEMORY_DIR/goals"
    mkdir -p "$AEK_HOME/memory/logs"
}

hr() {
    echo "---"
}

# === Process status helper ===
# Override WATCHDOG_PROCESS_NAME to match your main process
MAIN_PROCESS="${WATCHDOG_PROCESS_NAME:-}"

process_status() {
    if [[ -z "$MAIN_PROCESS" ]]; then
        echo "NOT CONFIGURED (set WATCHDOG_PROCESS_NAME)"
        return
    fi
    local pid
    pid=$(pgrep -x "$MAIN_PROCESS" 2>/dev/null | head -1 || echo "")
    if [[ -n "$pid" ]]; then
        echo "RUNNING (PID: $pid)"
    else
        echo "DOWN"
    fi
}

process_uptime() {
    if [[ -z "$MAIN_PROCESS" ]]; then
        echo "N/A"
        return
    fi
    local pid
    pid=$(pgrep -x "$MAIN_PROCESS" 2>/dev/null | head -1 || echo "")
    if [[ -n "$pid" ]]; then
        ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?"
    else
        echo "N/A"
    fi
}

# === Disk space helper ===
disk_summary() {
    local pct
    pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    local free
    free=$(df -h / | tail -1 | awk '{print $4}')
    echo "${pct}% used ($free free)"
}

# === Memory stats helper ===
memory_stats() {
    local knowledge_count=0
    local reflection_count=0

    knowledge_count=$(find "$MEMORY_DIR/knowledge" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    reflection_count=$(find "$MEMORY_DIR/reflections" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

    echo "  Knowledge: $knowledge_count files | Reflections: $reflection_count files"
}

# === Goals helper ===
read_goals() {
    if [[ -f "$GOALS_FILE" ]]; then
        python3 - "$GOALS_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    goals = data.get("goals", [])
    for g in goals:
        status_icon = {"active": "[~]", "pending": "[ ]", "completed": "[x]", "blocked": "[!]"}.get(g.get("status", ""), "[ ]")
        progress = g.get("progress", 0)
        bar_len = int(progress / 5)
        bar = "#" * bar_len + "." * (20 - bar_len)
        print(f'  {status_icon} **{g.get("title", g.get("name", "?"))}** [{bar}] {progress}%')
        if g.get("next_action"):
            print(f'      Next: {g["next_action"]}')
except Exception as e:
    print(f"  Could not read goals: {e}")
PYEOF
    else
        echo "  No goals file found ($GOALS_FILE)"
    fi
}

# === Cron status helper ===
cron_status() {
    local cron_count
    cron_count=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')
    echo "  $cron_count active cron jobs"
}

# === Briefing Sections ===

section_priority() {
    echo "### 1. PRIORITY ITEMS"
    echo ""

    # Main process health
    if [[ -n "$MAIN_PROCESS" ]]; then
        local status
        status=$(process_status)
        if [[ "$status" == *"DOWN"* ]]; then
            echo "  **CRITICAL:** Main process is DOWN!"
        fi
    fi

    # Disk space check
    local disk_pct
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ $disk_pct -ge 90 ]]; then
        echo "  **CRITICAL:** Disk ${disk_pct}% full!"
    elif [[ $disk_pct -ge 80 ]]; then
        echo "  **WARNING:** Disk ${disk_pct}% full"
    fi

    echo "  No other urgent items."
    echo ""
}

section_goals() {
    echo "### 2. GOALS"
    echo ""
    read_goals
    echo ""
}

section_system() {
    echo "### 3. SYSTEM STATUS"
    echo ""
    if [[ -n "$MAIN_PROCESS" ]]; then
        echo "  **Process:** $(process_status) | Uptime: $(process_uptime)"
    fi
    echo "  **Disk:** $(disk_summary)"
    echo ""
    echo "  **Memory:**"
    memory_stats
    echo ""
    echo "  **Cron:**"
    cron_status
    echo ""
}

section_metrics_summary() {
    echo "### 4. METRICS (24h)"
    echo ""
    if [[ -f "$METRICS_DB" ]]; then
        local task_count
        task_count=$(sqlite3 "$METRICS_DB" "SELECT COUNT(*) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
        local total_cost
        total_cost=$(sqlite3 "$METRICS_DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
        local success_rate
        success_rate=$(sqlite3 "$METRICS_DB" "
            SELECT ROUND(
                CAST(SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END) AS FLOAT) /
                NULLIF(COUNT(*), 0) * 100, 0
            ) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');
        " 2>/dev/null || echo "0")
        echo "  Tasks: $task_count | Success rate: ${success_rate:-0}% | Cost: \$${total_cost:-0}"
    else
        echo "  Metrics database not initialized (run: metrics.sh init)"
    fi
    echo ""
}

# === Midday Sections ===

section_unresolved() {
    echo "### Unresolved Items"
    echo ""

    local morning_file="$BRIEFING_DIR/${TODAY}-morning.md"
    if [[ -f "$morning_file" ]]; then
        local issues
        issues=$(grep -c "CRITICAL\|WARNING" "$morning_file" 2>/dev/null || echo "0")
        if [[ $issues -gt 0 ]]; then
            echo "  $issues open alerts from morning briefing:"
            grep "CRITICAL\|WARNING" "$morning_file" 2>/dev/null | while read -r line; do
                echo "  $line"
            done
        else
            echo "  No open items from morning briefing"
        fi
    else
        echo "  No morning briefing found"
    fi
    echo ""
}

section_new_alerts() {
    echo "### New Alerts"
    echo ""

    if [[ -n "$MAIN_PROCESS" ]]; then
        local status
        status=$(process_status)
        if [[ "$status" == *"DOWN"* ]]; then
            echo "  **CRITICAL:** Main process is DOWN!"
        else
            echo "  Process: $status"
        fi
    fi

    local disk_pct
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ $disk_pct -ge 85 ]]; then
        echo "  **WARNING:** Disk ${disk_pct}%"
    fi

    echo ""
}

# === Evening Sections ===

section_completed_tasks() {
    echo "### Completed Tasks"
    echo ""

    if [[ -f "$METRICS_DB" ]]; then
        local completed
        completed=$(sqlite3 "$METRICS_DB" "
            SELECT COUNT(*) FROM task_log
            WHERE date(ts) = date('now', 'localtime')
            AND status IN ('SUCCESS','completed','success');
        " 2>/dev/null || echo "0")
        local failed
        failed=$(sqlite3 "$METRICS_DB" "
            SELECT COUNT(*) FROM task_log
            WHERE date(ts) = date('now', 'localtime')
            AND status IN ('FAILED','failed','error');
        " 2>/dev/null || echo "0")
        echo "  Today: $completed successful, $failed failed tasks"
    fi
    echo ""
}

section_pending_items() {
    echo "### Pending Items"
    echo ""

    local briefings_today
    briefings_today=$(find "$BRIEFING_DIR" -name "${TODAY}-*" 2>/dev/null)
    local total_warnings=0
    for bf in $briefings_today; do
        local w
        w=$(grep -c "CRITICAL\|WARNING" "$bf" 2>/dev/null | tail -1 || echo "0")
        w=$(echo "$w" | tr -d '[:space:]')
        total_warnings=$((total_warnings + w))
    done

    if [[ $total_warnings -gt 0 ]]; then
        echo "  $total_warnings unresolved warnings from today"
    else
        echo "  No open warnings"
    fi

    if [[ -n "$MAIN_PROCESS" ]]; then
        echo "  Process: $(process_status)"
    fi
    echo ""
}

# === Briefing Composers ===

compose_morning() {
    local output="$BRIEFING_DIR/${TODAY}-morning.md"

    {
        echo "# Morning Briefing"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_priority
        hr
        section_goals
        hr
        section_system
        hr
        section_metrics_summary
        hr
        echo ""
        echo "*Briefing completed at $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Morning briefing saved: $output"
}

compose_midday() {
    local output="$BRIEFING_DIR/${TODAY}-midday.md"

    {
        echo "# Midday Check-in"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_unresolved
        hr
        section_new_alerts
        hr
        echo "### Quick Stats"
        echo ""
        if [[ -n "$MAIN_PROCESS" ]]; then
            echo "  Process: $(process_status) | Uptime: $(process_uptime)"
        fi
        echo "  Disk: $(disk_summary)"
        section_metrics_summary
        hr
        echo ""
        echo "*Check-in completed at $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Midday briefing saved: $output"
}

compose_evening() {
    local output="$BRIEFING_DIR/${TODAY}-evening.md"

    {
        echo "# Evening Review"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_completed_tasks
        hr
        section_pending_items
        hr
        section_goals
        hr
        section_system
        hr
        echo ""
        echo "*Evening review completed at $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Evening briefing saved: $output"
}

compose_custom() {
    local topic="${1:?Topic is required}"
    local safe_topic
    safe_topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | head -c50)
    local output="$BRIEFING_DIR/${TODAY}-custom-${safe_topic}.md"

    {
        echo "# Custom Briefing: $topic"
        echo "## $TODAY $NOW"
        echo ""
        hr

        case "$topic" in
            cost)
                echo "### Cost Report"
                echo ""
                local metrics_script="$AEK_HOME/scripts/metrics.sh"
                if [[ -x "$metrics_script" ]]; then
                    "$metrics_script" cost 7 2>/dev/null || echo "  No metrics data"
                else
                    echo "  metrics.sh not found"
                fi
                ;;

            goals)
                echo "### Goal Details"
                echo ""
                read_goals
                ;;

            disk)
                echo "### Disk Detail Report"
                echo ""
                echo "  **Overview:** $(disk_summary)"
                echo ""
                echo "  **Large directories:**"
                du -sh "$AEK_HOME" 2>/dev/null | awk '{print "    AEK_HOME: "$1}'
                du -sh "$AEK_HOME/memory" 2>/dev/null | awk '{print "    memory/: "$1}'
                echo ""
                echo "  **Large files (>50MB):**"
                find "$HOME" -maxdepth 4 -size +50M \
                    -not -path "*/Library/*" \
                    -not -path "*/.Trash/*" \
                    -not -path "*/node_modules/*" 2>/dev/null | head -10 | while read -r f; do
                    local sz
                    sz=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
                    echo "    $sz  $f"
                done
                ;;

            memory)
                echo "### Memory Details"
                echo ""
                memory_stats
                echo ""
                echo "  **Categories:**"
                for dir in knowledge reflections decisions; do
                    local cnt
                    cnt=$(find "$MEMORY_DIR/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                    echo "    $dir: $cnt files"
                done
                echo ""
                echo "  **Recently written (24h):**"
                find "$MEMORY_DIR" -maxdepth 2 -name "*.md" -newer "$MEMORY_DIR" -mtime -1 2>/dev/null | head -10 | while read -r f; do
                    echo "    $(basename "$f")"
                done
                ;;

            *)
                echo "### General Status: $topic"
                echo ""
                echo "  Known topics: cost, goals, disk, memory"
                echo "  '$topic' has no specific handler — showing general info."
                echo ""
                section_system
                ;;
        esac

        hr
        echo ""
        echo "*Custom briefing completed at $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Custom briefing saved: $output"
}

# === Help ===
cmd_help() {
    cat <<'HELP'
briefing.sh — Tri-Phase Daily Briefing System

Usage:
  morning              Morning briefing (08:00)
  midday               Midday check-in (13:00)
  evening              Evening review (21:00)
  custom <topic>       On-demand topic briefing

Custom Topics:
  cost                 Cost analysis report
  goals                Goal tracking detail
  disk                 Disk usage analysis
  memory               Memory file statistics

Options:
  --help, -h           Show this help message

Briefings are saved to: $AEK_HOME/memory/briefings/YYYY-MM-DD-{phase}.md

Cron Examples:
  0 8 * * *   /path/to/scripts/briefing.sh morning
  0 13 * * *  /path/to/scripts/briefing.sh midday
  0 21 * * *  /path/to/scripts/briefing.sh evening
HELP
}

# === Main ===
main() {
    ensure_dirs

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        morning)    compose_morning ;;
        midday)     compose_midday ;;
        evening)    compose_evening ;;
        custom)     compose_custom "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run: briefing.sh help"
            exit 1
            ;;
    esac
}

main "$@"
