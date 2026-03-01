#!/bin/bash
# metrics.sh — Multi-agent metrics system
# SQLite tabanli, lightweight metrik toplama ve raporlama
#
# Kullanim:
#   metrics.sh record <agent> <metric> <value> [tags]
#   metrics.sh dashboard                 # Son 24 saat ozeti
#   metrics.sh weekly                    # 7 gunluk trend
#   metrics.sh agent <name>              # Agent bazli istatistik
#   metrics.sh cost [days]               # Model/agent maliyet raporu
#   metrics.sh export [json|csv]         # Veri disa aktarimi
#   metrics.sh task <agent> <task_type> <status> [duration_ms] [tokens_in] [tokens_out] [model] [error]
#   metrics.sh init                      # DB'yi sifirdan olustur (mevcut varsa dokunmaz)

set -euo pipefail

# --- Config ---
DB_DIR="$HOME/clawd/memory"
DB="$DB_DIR/metrics.db"
LOG="/tmp/metrics.log"

# Model pricing — Bash 3.2 uyumlu (macOS default)
# calc_cost icinde Python ile hesaplanir

# Pre-defined metric names
VALID_METRICS="task_success task_failure token_count response_time_ms error_count memory_recall_hit memory_store rollback_count custom"

# --- Logging ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# --- DB Init ---
ensure_db() {
    mkdir -p "$DB_DIR"
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

# --- Cost Calculation (Bash 3.2 compatible — no associative arrays) ---
calc_cost() {
    local model="${1:-unknown}"
    local tokens_in="${2:-0}"
    local tokens_out="${3:-0}"

    python3 -c "
PRICING = {
    'opus':       (15.00, 75.00),
    'sonnet':     (3.00,  15.00),
    'haiku':      (0.80,  4.00),
    'flash':      (0.075, 0.30),
    'groq':       (0.00,  0.00),
    'nvidia':     (0.00,  0.00),
    'gpt-4o':     (2.50,  10.00),
    'gpt-4o-mini':(0.15,  0.60),
    'o1':         (15.00, 60.00),
    'o3-mini':    (1.10,  4.40),
    'deepseek':   (0.27,  1.10),
    'codex':      (0.00,  0.00),
    'unknown':    (0.00,  0.00),
}
model = '$model'
t_in = $tokens_in
t_out = $tokens_out
in_p, out_p = PRICING.get(model, (0.0, 0.0))
cost = (t_in / 1_000_000) * in_p + (t_out / 1_000_000) * out_p
print(f'{cost:.6f}')
" 2>/dev/null || echo "0.000000"
}

# --- Import cost-log.jsonl into task_log (idempotent helper) ---
import_cost_log() {
    local cost_log="$HOME/clawd/memory/cost-log.jsonl"
    [[ ! -f "$cost_log" ]] && return 0

    # Only import entries not already in task_log
    local last_ts
    last_ts=$(sqlite3 "$DB" "SELECT MAX(ts) FROM task_log WHERE task_type='bridge_call';" 2>/dev/null || echo "")

    python3 - "$cost_log" "$DB" "$last_ts" <<'PYEOF'
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
        duration = int(entry.get("duration", 0)) * 1000  # seconds to ms
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

# --- Commands ---

cmd_record() {
    local agent="${1:?Agent adi gerekli}"
    local metric="${2:?Metrik adi gerekli}"
    local value="${3:?Deger gerekli}"
    local tags="${4:-}"

    ensure_db

    sqlite3 "$DB" "INSERT INTO metrics (agent, metric, value, tags) VALUES ('$agent', '$metric', $value, '$tags');"
    log "RECORD: agent=$agent metric=$metric value=$value tags=$tags"
    echo "Kaydedildi: $agent/$metric = $value"
}

cmd_task() {
    local agent="${1:?Agent adi gerekli}"
    local task_type="${2:?Task type gerekli}"
    local status="${3:?Status gerekli (SUCCESS/FAILED)}"
    local duration_ms="${4:-0}"
    local tokens_in="${5:-0}"
    local tokens_out="${6:-0}"
    local model="${7:-unknown}"
    local error="${8:-}"

    ensure_db

    local cost
    cost=$(calc_cost "$model" "$tokens_in" "$tokens_out")

    sqlite3 "$DB" "INSERT INTO task_log (agent, task_type, status, duration_ms, tokens_input, tokens_output, model, cost_estimate, error) VALUES ('$agent', '$task_type', '$status', $duration_ms, $tokens_in, $tokens_out, '$model', $cost, '$error');"
    log "TASK: agent=$agent type=$task_type status=$status model=$model cost=$cost"
    echo "Task kaydedildi: $agent/$task_type [$status] cost=\$$cost"
}

cmd_dashboard() {
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Oracle Metrics Dashboard"
    echo "### Son 24 Saat — $(date '+%Y-%m-%d %H:%M')"
    echo ""

    # Task summary per agent
    echo "### Agent Performansi"
    echo '```'
    printf "%-14s %6s %6s %6s %10s\n" "Agent" "Basari" "Fail" "Oran%" "Maliyet"
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

    # Token usage
    echo "### Token Kullanimi"
    echo '```'
    printf "%-10s %12s %12s %10s\n" "Model" "Input" "Output" "Maliyet"
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

    # Metric highlights
    echo "### Metrik Ozetleri"
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
        printf "  %-25s  sayi: %5s  ort: %8s  toplam: %10s\n" "$metric" "$cnt" "$avg" "$total"
    done
    echo '```'
    echo ""

    # Total task count
    local total_24h
    total_24h=$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
    local total_cost
    total_cost=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0.0")

    echo "**Toplam:** $total_24h task | \$${total_cost:-0} maliyet"
}

cmd_weekly() {
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Oracle Weekly Trend"
    echo "### Son 7 Gun — $(date '+%Y-%m-%d')"
    echo ""

    echo "### Gunluk Ozet"
    echo '```'
    printf "%-12s %6s %6s %6s %10s\n" "Tarih" "Basari" "Fail" "Toplam" "Maliyet"
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

    # Agent breakdown for the week
    echo "### Agent Haftalik Ozet"
    echo '```'
    printf "%-14s %6s %6s %6s %10s %10s\n" "Agent" "Basari" "Fail" "Oran%" "Ort.sure" "Maliyet"
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

    # Model usage for the week
    echo "### Model Kullanimi (7 Gun)"
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
        printf "  %-10s  %5s cagri  in: %10s  out: %10s  \$%s\n" "$model" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'

    local total_week
    total_week=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-7 days', 'localtime');" 2>/dev/null || echo "0.0")
    echo ""
    echo "**Haftalik toplam maliyet:** \$${total_week:-0}"
}

cmd_agent() {
    local name="${1:?Agent adi gerekli}"
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Agent Raporu: $name"
    echo "### $(date '+%Y-%m-%d %H:%M')"
    echo ""

    # Task summary
    echo "### Task Ozeti (Son 7 Gun)"
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
        printf "  %-20s  ok: %3s  fail: %3s  ort: %6ss  \$%s\n" "$task_type" "$ok" "$fail" "$avg_s" "$cost"
    done
    echo '```'
    echo ""

    # Model usage
    echo "### Model Kullanimi"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT
            model,
            COUNT(*),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE agent='$name' AND ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY model
        ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r model cnt cost; do
        printf "  %-10s  %5s cagri  \$%s\n" "$model" "$cnt" "$cost"
    done
    echo '```'
    echo ""

    # Recent errors
    echo "### Son Hatalar"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT ts, task_type, model, error
        FROM task_log
        WHERE agent='$name' AND status IN ('FAILED','failed','error') AND error != ''
        ORDER BY ts DESC
        LIMIT 5;
    " 2>/dev/null | while IFS='|' read -r ts task_type model error; do
        echo "  [$ts] $task_type ($model): $error"
    done || echo "  (hata yok)"
    echo '```'
    echo ""

    # Metric summary
    echo "### Metrikler"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT metric, COUNT(*), ROUND(AVG(value), 2), ROUND(SUM(value), 2)
        FROM metrics
        WHERE agent='$name' AND ts >= datetime('now', '-7 days', 'localtime')
        GROUP BY metric
        ORDER BY COUNT(*) DESC;
    " 2>/dev/null | while IFS='|' read -r metric cnt avg total; do
        printf "  %-25s  sayi: %5s  ort: %8s  toplam: %10s\n" "$metric" "$cnt" "$avg" "$total"
    done || echo "  (metrik yok)"
    echo '```'
}

cmd_cost() {
    local days="${1:-7}"
    ensure_db
    import_cost_log 2>/dev/null || true

    echo "## Maliyet Raporu — Son $days Gun"
    echo "### $(date '+%Y-%m-%d %H:%M')"
    echo ""

    # By agent
    echo "### Agent Bazli"
    echo '```'
    printf "%-14s %6s %12s %12s %10s\n" "Agent" "Cagri" "Input Tok" "Output Tok" "Maliyet"
    printf "%-14s %6s %12s %12s %10s\n" "--------------" "------" "------------" "------------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            agent,
            COUNT(*),
            SUM(tokens_input),
            SUM(tokens_output),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY agent
        ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r agent cnt tin tout cost; do
        printf "%-14s %6s %12s %12s \$%9s\n" "$agent" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'
    echo ""

    # By model
    echo "### Model Bazli"
    echo '```'
    printf "%-10s %6s %12s %12s %10s\n" "Model" "Cagri" "Input Tok" "Output Tok" "Maliyet"
    printf "%-10s %6s %12s %12s %10s\n" "----------" "------" "------------" "------------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            model,
            COUNT(*),
            SUM(tokens_input),
            SUM(tokens_output),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY model
        ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r model cnt tin tout cost; do
        printf "%-10s %6s %12s %12s \$%9s\n" "$model" "$cnt" "$tin" "$tout" "$cost"
    done
    echo '```'
    echo ""

    # By agent+model cross
    echo "### Agent x Model Detay"
    echo '```'
    printf "%-14s %-10s %6s %10s\n" "Agent" "Model" "Cagri" "Maliyet"
    printf "%-14s %-10s %6s %10s\n" "--------------" "----------" "------" "----------"

    sqlite3 -separator '|' "$DB" "
        SELECT
            agent,
            model,
            COUNT(*),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY agent, model
        ORDER BY SUM(cost_estimate) DESC;
    " 2>/dev/null | while IFS='|' read -r agent model cnt cost; do
        printf "%-14s %-10s %6s \$%9s\n" "$agent" "$model" "$cnt" "$cost"
    done
    echo '```'
    echo ""

    # Daily cost trend
    echo "### Gunluk Maliyet Trendi"
    echo '```'
    sqlite3 -separator '|' "$DB" "
        SELECT
            date(ts),
            COUNT(*),
            ROUND(SUM(cost_estimate), 4)
        FROM task_log
        WHERE ts >= datetime('now', '-$days days', 'localtime')
        GROUP BY date(ts)
        ORDER BY date(ts) DESC;
    " 2>/dev/null | while IFS='|' read -r dt cnt cost; do
        # Simple bar chart
        local bar_len
        bar_len=$(python3 -c "print(int(min(float('${cost:-0}') * 100, 50)))" 2>/dev/null || echo "0")
        local bar=""
        for ((i=0; i<bar_len; i++)); do bar+="#"; done
        printf "  %s  %4s cagri  \$%8s  %s\n" "$dt" "$cnt" "$cost" "$bar"
    done
    echo '```'

    local total
    total=$(sqlite3 "$DB" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-$days days', 'localtime');" 2>/dev/null || echo "0.0")
    echo ""
    echo "**Toplam maliyet ($days gun):** \$${total:-0}"
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
            echo "Bilinmeyen format: $format (json veya csv kullan)"
            exit 1
            ;;
    esac
}

cmd_help() {
    cat <<'HELP'
metrics.sh — Multi-agent Metrics System

Kullanim:
  record <agent> <metric> <value> [tags]    Metrik kaydet
  task <agent> <type> <status> [dur] [tin] [tout] [model] [err]
                                             Task kaydi olustur
  dashboard                                  Son 24 saat ozeti
  weekly                                     7 gunluk trend
  agent <name>                               Agent bazli istatistik
  cost [days]                                Maliyet raporu (default: 7 gun)
  export [json|csv]                          Veri disa aktarimi
  init                                       DB olustur/dogrula

Metrik isimleri:
  task_success, task_failure, token_count, response_time_ms,
  error_count, memory_recall_hit, memory_store, rollback_count, custom

Model fiyatlari (input/1M token):
  opus=$15  sonnet=$3  haiku=$0.80  flash=$0.075
  groq=free  nvidia=free  gpt-4o=$2.50

Ornekler:
  metrics.sh record scout task_success 1 "nightly-scan"
  metrics.sh task analyst research SUCCESS 12000 500 800 sonnet
  metrics.sh dashboard
  metrics.sh cost 30
HELP
}

# --- Main ---
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
        init)       ensure_db; echo "DB hazir: $DB" ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Bilinmeyen komut: $cmd"
            echo "Kullanim icin: metrics.sh help"
            exit 1
            ;;
    esac
}

main "$@"
