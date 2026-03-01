#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# metrics.sh — SQLite-based multi-agent metrics collection and reporting
#
# Usage:
#   metrics.sh record <agent> <metric> <value> [tags]
#   metrics.sh task <agent> <task_type> <status> [duration_ms] [tokens_in] [tokens_out] [model] [error]
#   metrics.sh dashboard                # Last 24 hours summary
#   metrics.sh weekly                   # 7-day trend report
#   metrics.sh agent <name>             # Agent-specific stats
#   metrics.sh cost [days]              # Cost analysis report
#   metrics.sh export [json|csv]        # Data export
#   metrics.sh init                     # Initialize database

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
DB_DIR="$AEK_HOME/memory"
DB="$DB_DIR/metrics.db"
LOG="$AEK_HOME/memory/logs/metrics.log"
COST_LOG="$AEK_HOME/memory/cost-log.jsonl"

# === Logging ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# === Database Initialization ===
ensure_db() {
    mkdir -p "$DB_DIR"
    mkdir -p "$AEK_HOME/memory/logs"
    if [[ ! -f "$DB" ]]; then
        log "Creating new metrics database: $DB"
        init_db
    fi
}

init_db() {
    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')),
    agent TEXT NOT NULL,
    metric TEXT NOT NULL,
    value REAL NOT NULL DEFAULT 0,
    tags TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS task_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')),
    agent TEXT NOT NULL,
    task_type TEXT NOT NULL DEFAULT 'generic',
    status TEXT NOT NULL DEFAULT 'unknown',
    duration_ms INTEGER DEFAULT 0,
    tokens_input INTEGER DEFAULT 0,
    tokens_output INTEGER DEFAULT 0,
    model TEXT DEFAULT 'unknown',
    cost_estimate REAL DEFAULT 0.0,
    error TEXT DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics(ts);
CREATE INDEX IF NOT EXISTS idx_metrics_agent ON metrics(agent);
CREATE INDEX IF NOT EXISTS idx_metrics_metric ON metrics(metric);
CREATE INDEX IF NOT EXISTS idx_task_log_ts ON task_log(ts);
CREATE INDEX IF NOT EXISTS idx_task_log_agent ON task_log(agent);
CREATE INDEX IF NOT EXISTS idx_task_log_model ON task_log(model);
SQL
    log "Database initialized: $DB"
}

# === Cost Calculation ===
calc_cost() {
    local model="${1:-unknown}"
    local tokens_in="${2:-0}"
    local tokens_out="${3:-0}"

    python3 - "$model" "$tokens_in" "$tokens_out" 2>/dev/null <<'PYEOF' || echo "0.000000"
import sys
# Pricing per 1M tokens: (input, output)
PRICING = {
    'opus':       (15.00, 75.00),
    'sonnet':     (3.00,  15.00),
    'haiku':      (0.80,  4.00),
    'flash':      (0.075, 0.30),
    'gpt-4o':     (2.50,  10.00),
    'gpt-4o-mini':(0.15,  0.60),
    'o1':         (15.00, 60.00),
    'o3-mini':    (1.10,  4.40),
    'deepseek':   (0.27,  1.10),
    'unknown':    (0.00,  0.00),
}
model = sys.argv[1]
t_in = int(sys.argv[2])
t_out = int(sys.argv[3])
in_p, out_p = PRICING.get(model, (0.0, 0.0))
cost = (t_in / 1_000_000) * in_p + (t_out / 1_000_000) * out_p
print(f'{cost:.6f}')
PYEOF
}

# === Import cost-log.jsonl into task_log ===
import_cost_log() {
    [[ ! -f "$COST_LOG" ]] && return 0

    local last_ts
    last_ts=$(sqlite3 "$DB" "SELECT MAX(ts) FROM task_log WHERE task_type='bridge_call';" 2>/dev/null || echo "")

    python3 - "$COST_LOG" "$DB" "$last_ts" <<'PYEOF'
import json, sqlite3, sys

cost_log = sys.argv[1]
db_path = sys.argv[2]
last_ts = sys.argv[3] if len(sys.argv) > 3 else ""

conn = sqlite3.connect(db_path)
cur = conn.cursor()
imported = 0

with open(cost_log, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        ts = entry.get("ts", "")
        if last_ts and ts <= last_ts:
            continue

        model = entry.get("model", "unknown")
        status = entry.get("status", "unknown")
        duration = int(entry.get("duration", 0)) * 1000
        caller = entry.get("caller", "manual")

        cur.execute(
            "INSERT INTO task_log (ts, agent, task_type, status, duration_ms, model) VALUES (?, ?, 'bridge_call', ?, ?, ?)",
            (ts, caller, status, duration, model)
        )
        imported += 1

conn.commit()
conn.close()
if imported > 0:
    print(f"Imported {imported} entries from cost-log.jsonl")
PYEOF
}

# === Commands ===

cmd_record() {
    local agent="${1:?Agent name required}"
    local metric="${2:?Metric name required}"
    local value="${3:?Value required}"
    local tags="${4:-}"

    ensure_db
    python3 - "$DB" "$agent" "$metric" "$value" "$tags" <<'PYEOF'
import sqlite3, sys
db, agent, metric, value, tags = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
conn = sqlite3.connect(db)
conn.execute("INSERT INTO metrics (agent, metric, value, tags) VALUES (?, ?, ?, ?)", (agent, metric, value, tags))
conn.commit()
conn.close()
PYEOF
    log "RECORD: agent=$agent metric=$metric value=$value tags=$tags"
    echo "Recorded: $agent/$metric = $value"
}

cmd_task() {
    local agent="${1:?Agent name required}"
    local task_type="${2:?Task type required}"
    local status="${3:?Status required (SUCCESS/FAILED)}"
    local duration_ms="${4:-0}"
    local tokens_in="${5:-0}"
    local tokens_out="${6:-0}"
    local model="${7:-unknown}"
    local error="${8:-}"

    ensure_db

    local cost
    cost=$(calc_cost "$model" "$tokens_in" "$tokens_out")

    python3 - "$DB" "$agent" "$task_type" "$status" "$duration_ms" "$tokens_in" "$tokens_out" "$model" "$cost" "$error" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
agent, task_type, status = sys.argv[2], sys.argv[3], sys.argv[4]
duration_ms, tokens_in, tokens_out = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
model, cost, error = sys.argv[8], float(sys.argv[9]), sys.argv[10]
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO task_log (agent, task_type, status, duration_ms, tokens_input, tokens_output, model, cost_estimate, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    (agent, task_type, status, duration_ms, tokens_in, tokens_out, model, cost, error)
)
conn.commit()
conn.close()
PYEOF
    log "TASK: agent=$agent type=$task_type status=$status model=$model cost=$cost"
    echo "Task recorded: $agent/$task_type [$status] cost=\$$cost"
}

cmd_dashboard() {
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Metrics Dashboard"
    echo "### Last 24 Hours — $(date '+%Y-%m-%d %H:%M')"
    echo ""

    # Agent performance
    echo "### Agent Performance"
    echo '```'
    printf "%-14s %6s %6s %6s %10s\n" "Agent" "OK" "Fail" "Rate%" "Cost"
    printf "%-14s %6s %6s %6s %10s\n" "--------------" "------" "------" "------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            agent,
            SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END),
            SUM(CASE WHEN status IN ('FAILED','failed','error') THEN 1 ELSE 0 END),
            COUNT(*),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-24 hours', 'localtime')
        GROUP BY agent
        ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r agent ok fail total cost; do
        if [[ "$total" -gt 0 ]]; then
            rate=$(python3 -c "print(f'{($ok/$total)*100:.0f}')" 2>/dev/null || echo "0")
        else
            rate="0"
        fi
        printf "%-14s %6s %6s %5s%% \$%9s\n" "$agent" "$ok" "$fail" "$rate" "$cost"
    done
    echo '```'
    echo ""

    # Token usage by model
    echo "### Token Usage"
    echo '```'
    printf "%-10s %12s %12s %10s\n" "Model" "Input" "Output" "Cost"
    printf "%-10s %12s %12s %10s\n" "----------" "------------" "------------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            model,
            SUM(tokens_input),
            SUM(tokens_output),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-24 hours', 'localtime')
        GROUP BY model
        ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r model tin tout cost; do
        printf "%-10s %12s %12s \$%9s\n" "$model" "$tin" "$tout" "$cost"
    done
    echo '```'
    echo ""

    # Metric summaries
    echo "### Metric Summaries"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT
            metric,
            COUNT(*),
            ROUND(AVG(value), 2),
            ROUND(SUM(value), 2)
        FROM metrics
        WHERE ts >= datetime('now', '-24 hours', 'localtime')
        GROUP BY metric
        ORDER BY COUNT(*) DESC
        LIMIT 10;
    " 2>/dev/null | while IFS='|' read -r metric cnt avg total; do
        printf "  %-25s  count: %5s  avg: %8s  total: %10s\n" "$metric" "$cnt" "$avg" "$total"
    done
    echo '```'
    echo ""

    # Totals
    local total_24h
    total_24h=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
    local total_cost
    total_cost=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0.0")

    echo "**Total:** $total_24h tasks | \$${total_cost:-0} cost"
}

cmd_weekly() {
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Weekly Trend Report"
    echo "### Last 7 Days — $(date '+%Y-%m-%d')"
    echo ""

    echo "### Daily Summary"
    echo '```'
    printf "%-12s %6s %6s %6s %10s\n" "Date" "OK" "Fail" "Total" "Cost"
    printf "%-12s %6s %6s %6s %10s\n" "------------" "------" "------" "------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            date(ts),
            SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END),
            SUM(CASE WHEN status IN ('FAILED','failed','error') THEN 1 ELSE 0 END),
            COUNT(*),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY date(ts)
        ORDER BY date(ts) DESC;
    " 2>/dev/null | while IFS='|' read -r dt ok fail total cost; do
        printf "%-12s %6s %6s %6s \$%9s\n" "$dt" "$ok" "$fail" "$total" "$cost"
    done
    echo '```'
    echo ""

    # Agent weekly breakdown
    echo "### Agent Weekly Summary"
    echo '```'
    printf "%-14s %6s %6s %6s %10s %10s\n" "Agent" "OK" "Fail" "Rate%" "Avg(s)" "Cost"
    printf "%-14s %6s %6s %6s %10s %10s\n" "--------------" "------" "------" "------" "----------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            agent,
            SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END),
            SUM(CASE WHEN status IN ('FAILED','failed','error') THEN 1 ELSE 0 END),
            COUNT(*),
            ROUND(AVG(duration_ms)/1000.0, 1),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY agent
        ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r agent ok fail total avg_s cost; do
        if [[ "$total" -gt 0 ]]; then
            rate=$(python3 -c "print(f'{($ok/$total)*100:.0f}')" 2>/dev/null || echo "0")
        else
            rate="0"
        fi
        printf "%-14s %6s %6s %5s%% %9ss \$%9s\n" "$agent" "$ok" "$fail" "$rate" "$avg_s" "$cost"
    done
    echo '```'
    echo ""

    # Model usage
    echo "### Model Usage (7 Days)"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT
            model,
            COUNT(*),
            SUM(tokens_input),
            SUM(tokens_output),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY model
        ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r model cnt tin tout cost; do
        printf "  %-10s  %5s calls  in: %10s  out: %10s  \$%s\n" "$model" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'

    local total_week
    total_week=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-7 days', 'localtime');" 2>/dev/null || echo "0.0")
    echo ""
    echo "**Weekly total cost:** \$${total_week:-0}"
}

cmd_agent() {
    local name="${1:?Agent name required}"
    # Sanitize agent name for SQL safety (whitelist: alphanumeric, hyphen, underscore)
    name=$(echo "$name" | sed 's/[^a-zA-Z0-9_-]//g')
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Agent Report: $name"
    echo "### $(date '+%Y-%m-%d %H:%M')"
    echo ""

    echo "### Task Summary (Last 7 Days)"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT
            task_type,
            SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END) as ok,
            SUM(CASE WHEN status IN ('FAILED','failed','error') THEN 1 ELSE 0 END) as fail,
            COUNT(*) as total,
            ROUND(AVG(duration_ms)/1000.0, 1) as avg_s,
            ROUND(SUM(cost_estimate), 4) as cost
        FROM task_log
        WHERE agent='$name' AND ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY task_type
        ORDER BY total DESC;
    " 2>/dev/null | while IFS='|' read -r task_type ok fail total avg_s cost; do
        printf "  %-20s  ok: %3s  fail: %3s  avg: %6ss  \$%s\n" "$task_type" "$ok" "$fail" "$avg_s" "$cost"
    done
    echo '```'
    echo ""

    echo "### Model Usage"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT model, COUNT(*), ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE agent='$name' AND ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY model ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r model cnt cost; do
        printf "  %-10s  %5s calls  \$%s\n" "$model" "$cnt" "$cost"
    done
    echo '```'
    echo ""

    echo "### Recent Errors"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT ts, task_type, model, error
        FROM task_log
        WHERE agent='$name' AND status IN ('FAILED','failed','error') AND error != ''
        ORDER BY ts DESC LIMIT 5;
    " 2>/dev/null | while IFS='|' read -r ts task_type model error; do
        echo "  [$ts] $task_type ($model): $error"
    done || echo "  (no errors)"
    echo '```'
    echo ""

    echo "### Metrics"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT metric, COUNT(*), ROUND(AVG(value), 2), ROUND(SUM(value), 2)
        FROM metrics
        WHERE agent='$name' AND ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY metric ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r metric cnt avg total; do
        printf "  %-25s  count: %5s  avg: %8s  total: %10s\n" "$metric" "$cnt" "$avg" "$total"
    done || echo "  (no metrics)"
    echo '```'
}

cmd_cost() {
    local days="${1:-7}"
    # Validate days is numeric
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Error: days must be a number"
        exit 1
    fi
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Cost Report — Last $days Days"
    echo "### $(date '+%Y-%m-%d %H:%M')"
    echo ""

    echo "### By Agent"
    echo '```'
    printf "%-14s %6s %12s %12s %10s\n" "Agent" "Calls" "Input Tok" "Output Tok" "Cost"
    printf "%-14s %6s %12s %12s %10s\n" "--------------" "------" "------------" "------------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT agent, COUNT(*), SUM(tokens_input), SUM(tokens_output), ROUND(SUM(cost_estimate), 4)
        FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY agent ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r agent cnt tin tout cost; do
        printf "%-14s %6s %12s %12s \$%9s\n" "$agent" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'
    echo ""

    echo "### By Model"
    echo '```'
    printf "%-10s %6s %12s %12s %10s\n" "Model" "Calls" "Input Tok" "Output Tok" "Cost"
    printf "%-10s %6s %12s %12s %10s\n" "----------" "------" "------------" "------------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT model, COUNT(*), SUM(tokens_input), SUM(tokens_output), ROUND(SUM(cost_estimate), 4)
        FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY model ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r model cnt tin tout cost; do
        printf "%-10s %6s %12s %12s \$%9s\n" "$model" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'
    echo ""

    echo "### Agent x Model Detail"
    echo '```'
    printf "%-14s %-10s %6s %10s\n" "Agent" "Model" "Calls" "Cost"
    printf "%-14s %-10s %6s %10s\n" "--------------" "----------" "------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT agent, model, COUNT(*), ROUND(SUM(cost_estimate), 4)
        FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY agent, model ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r agent model cnt cost; do
        printf "%-14s %-10s %6s \$%9s\n" "$agent" "$model" "$cnt" "$cost"
    done
    echo '```'
    echo ""

    echo "### Daily Cost Trend"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT date(ts), COUNT(*), ROUND(SUM(cost_estimate), 4)
        FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY date(ts) ORDER BY date(ts) DESC;
    " 2>/dev/null | while IFS='|' read -r dt cnt cost; do
        local bar_len
        bar_len=$(python3 -c "import sys; print(int(min(float(sys.argv[1]) * 100, 50)))" "${cost:-0}" 2>/dev/null || echo "0")
        local bar=""
        for ((i=0; i<bar_len; i++)); do bar+="#"; done
        printf "  %s  %4s calls  \$%8s  %s\n" "$dt" "$cnt" "$cost" "$bar"
    done
    echo '```'

    local total
    total=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime');" 2>/dev/null || echo "0.0")
    echo ""
    echo "**Total cost ($days days):** \$${total:-0}"
}

cmd_export() {
    local format="${1:-json}"
    ensure_db

    case "$format" in
        json)
            echo "{"
            echo '  "metrics": ['
            sqlite3 -json "$DB" "SELECT * FROM metrics ORDER BY ts DESC LIMIT 1000;" 2>/dev/null || echo "[]"
            echo '  ],'
            echo '  "task_log": ['
            sqlite3 -json "$DB" "SELECT * FROM task_log ORDER BY ts DESC LIMIT 1000;" 2>/dev/null || echo "[]"
            echo '  ],'
            echo "  \"exported_at\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
            echo "}"
            ;;
        csv)
            echo "--- metrics ---"
            sqlite3 -header -csv "$DB" "SELECT * FROM metrics ORDER BY ts DESC LIMIT 1000;" 2>/dev/null
            echo ""
            echo "--- task_log ---"
            sqlite3 -header -csv "$DB" "SELECT * FROM task_log ORDER BY ts DESC LIMIT 1000;" 2>/dev/null
            ;;
        *)
            echo "Unknown format: $format (use json or csv)"
            exit 1
            ;;
    esac
}

cmd_help() {
    cat <<'HELP'
metrics.sh — Multi-Agent Metrics System

Usage:
  record <agent> <metric> <value> [tags]    Record a metric
  task <agent> <type> <status> [dur] [tin] [tout] [model] [err]
                                             Record a task execution
  dashboard                                  Last 24 hours summary
  weekly                                     7-day trend report
  agent <name>                               Agent-specific stats
  cost [days]                                Cost report (default: 7 days)
  export [json|csv]                          Export data
  init                                       Create/verify database

Metric Names:
  task_success, task_failure, token_count, response_time_ms,
  error_count, memory_recall_hit, memory_store, rollback_count, custom

Model Pricing (input/1M tokens):
  opus=$15  sonnet=$3  haiku=$0.80  flash=$0.075
  gpt-4o=$2.50  o1=$15  deepseek=$0.27

Examples:
  metrics.sh record scout task_success 1 "nightly-scan"
  metrics.sh task analyst research SUCCESS 12000 500 800 sonnet
  metrics.sh dashboard
  metrics.sh cost 30
HELP
}

# === Main ===
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        record)     cmd_record "$@" ;;
        task)       cmd_task "$@" ;;
        dashboard)  cmd_dashboard ;;
        weekly)     cmd_weekly ;;
        agent)      cmd_agent "$@" ;;
        cost)       cmd_cost "$@" ;;
        export)     cmd_export "$@" ;;
        init)       ensure_db; echo "Database ready: $DB" ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run: metrics.sh help"
            exit 1
            ;;
    esac
}

main "$@"
