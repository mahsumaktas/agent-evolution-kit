#!/bin/bash
# briefing.sh — Tri-phase daily briefing system
# Sabah, ogle, aksam briefing'leri + on-demand custom briefing
#
# Kullanim:
#   briefing.sh morning              # 08:00 sabah briefing
#   briefing.sh midday               # 13:00 ogle check-in
#   briefing.sh evening              # 21:00 gun sonu review
#   briefing.sh custom <topic>       # On-demand briefing
#   briefing.sh --send               # Son briefing'i Telegram'a gonder

set -euo pipefail

# --- Config ---
CLAWD_DIR="${AGENT_HOME:-$HOME/.agent-evolution}"
MEMORY_DIR="$CLAWD_DIR/memory"
BRIEFING_DIR="$MEMORY_DIR/briefings"
GOALS_FILE="$MEMORY_DIR/goals/active-goals.json"
METRICS_SCRIPT="$CLAWD_DIR/scripts/metrics.sh"
SYSTEM_CHECK="$CLAWD_DIR/scripts/system-check.sh"
PATCHKIT_DIR="$HOME/agent-system-patchkit"
OPENCLAW_DIR="$HOME/.agent-system"
LOG="/tmp/briefing.log"
METRICS_DB="$MEMORY_DIR/metrics.db"
BLACKBOARD_SCRIPT="$CLAWD_DIR/scripts/blackboard.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H:%M')

# --- Helpers ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

ensure_dirs() {
    mkdir -p "$BRIEFING_DIR"
    mkdir -p "$MEMORY_DIR/goals"
}

hr() {
    echo "---"
}

# Gateway status helper
gateway_status() {
    local gw_pid
    gw_pid=$(pgrep -x agent-system-gateway 2>/dev/null | head -1 || echo "")

    if [[ -n "$gw_pid" ]]; then
        echo "RUNNING (PID: $gw_pid)"
    else
        echo "DOWN"
    fi
}

gateway_uptime() {
    local gw_pid
    gw_pid=$(pgrep -x agent-system-gateway 2>/dev/null | head -1 || echo "")
    if [[ -n "$gw_pid" ]]; then
        ps -o etime= -p "$gw_pid" 2>/dev/null | tr -d ' ' || echo "?"
    else
        echo "N/A"
    fi
}

gateway_errors_24h() {
    local log_file="$OPENCLAW_DIR/logs/gateway.log"
    if [[ -f "$log_file" ]]; then
        local cutoff
        cutoff=$(date -v-24H '+%Y-%m-%d' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || echo "")
        if [[ -n "$cutoff" ]]; then
            grep -ic "error" "$log_file" 2>/dev/null | tail -1 || echo "0"
        else
            tail -500 "$log_file" 2>/dev/null | grep -ic "error" | tail -1 || echo "0"
        fi
    else
        echo "log yok"
    fi
}

gateway_last_restart() {
    local log_file="$OPENCLAW_DIR/logs/gateway.log"
    if [[ -f "$log_file" ]]; then
        grep -i "started\|listening\|gateway ready\|logged in" "$log_file" 2>/dev/null | tail -1 | head -c 80 || echo "?"
    else
        echo "log dosyasi bulunamadi"
    fi
}

# Disk space helper
disk_summary() {
    local pct
    pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    local free
    free=$(df -h / | tail -1 | awk '{print $4}')
    echo "${pct}% dolu ($free bos)"
}

# Session size helper
session_sizes() {
    if [[ -d "$OPENCLAW_DIR/agents" ]]; then
        local total=0
        for agent_dir in "$OPENCLAW_DIR/agents"/*/; do
            local agent
            agent=$(basename "$agent_dir")
            local size
            size=$(du -sh "$agent_dir/sessions" 2>/dev/null | awk '{print $1}' || echo "0")
            local count
            count=$(find "$agent_dir/sessions" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$count" -gt 0 ]]; then
                echo "  $agent: $count session ($size)"
            fi
        done
    else
        echo "  Agent dizini bulunamadi"
    fi
}

# Memory stats helper
memory_stats() {
    local total_memories=0
    local knowledge_count=0
    local reflection_count=0
    local decision_count=0
    local recent_count=0

    knowledge_count=$(find "$MEMORY_DIR/knowledge" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    reflection_count=$(find "$MEMORY_DIR/reflections" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    decision_count=$(find "$MEMORY_DIR/decisions" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    recent_count=$(find "$MEMORY_DIR" -maxdepth 1 -name "*.md" -newer "$MEMORY_DIR" -mtime -1 2>/dev/null | wc -l | tr -d ' ')
    total_memories=$((knowledge_count + reflection_count + decision_count))

    echo "  Toplam: $total_memories"
    echo "  Knowledge: $knowledge_count | Reflections: $reflection_count | Decisions: $decision_count"
    echo "  Son 24h yeni: $recent_count"
}

# Cron status helper
cron_status() {
    local cron_count
    cron_count=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')
    echo "  $cron_count aktif cron job"

    # Check for failed recent runs via logs
    local failed_crons=0
    for logfile in "$MEMORY_DIR/bridge-logs"/daily-check-*.log; do
        if [[ -f "$logfile" ]]; then
            if grep -qi "KRITIK\|FAIL\|ERROR" "$logfile" 2>/dev/null; then
                failed_crons=$((failed_crons + 1))
            fi
        fi
    done 2>/dev/null

    if [[ $failed_crons -gt 0 ]]; then
        echo "  SON HATALI CRON: $failed_crons"
    else
        echo "  Son cron log'lari temiz"
    fi
}

# Goals helper
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
            print(f'      Sonraki: {g["next_action"]}')
except Exception as e:
    print(f"  Goals okunamadi: {e}")
PYEOF
    else
        echo "  Goals dosyasi bulunamadi ($GOALS_FILE)"
    fi
}

# Nightly scan results helper
nightly_scan_summary() {
    if [[ -d "$PATCHKIT_DIR" ]]; then
        local scan_log="$PATCHKIT_DIR/nightly-scan-results.json"
        local scan_md="$PATCHKIT_DIR/nightly-scan-latest.md"

        if [[ -f "$scan_md" ]]; then
            local mod_date
            mod_date=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$scan_md" 2>/dev/null || echo "?")
            echo "  Son scan: $mod_date"
            head -20 "$scan_md" 2>/dev/null | while read -r line; do
                echo "  $line"
            done
        elif [[ -f "$scan_log" ]]; then
            local mod_date
            mod_date=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$scan_log" 2>/dev/null || echo "?")
            echo "  Son scan: $mod_date"
            python3 - "$scan_log" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    total = data.get("total_scanned", "?")
    high = len([p for p in data.get("results", []) if p.get("tier") in ("critical", "high")])
    print(f"  Taranan: {total} PR | Yuksek skor: {high}")
except:
    print("  Scan sonuclari okunamadi")
PYEOF
        else
            echo "  Nightly scan sonucu bulunamadi"
        fi

        # Patch count
        local patch_count
        patch_count=$(find "$HOME/.agent-system/my-patches/manual-patches" -name "PR-*.sh" -o -name "FIX-*.sh" 2>/dev/null | wc -l | tr -d ' ')
        echo "  Aktif patch sayisi: $patch_count"
    else
        echo "  Patchkit dizini bulunamadi"
    fi
}

# --- Briefing Sections ---

section_priority() {
    echo "### 1. ONCELIK"
    echo ""

    # Gateway health first
    local gw_status
    gw_status=$(gateway_status)
    if [[ "$gw_status" == *"DOWN"* ]]; then
        echo "  **KRITIK:** Gateway DOWN!"
    fi

    # Gateway errors
    local err_count
    err_count=$(gateway_errors_24h)
    if [[ "$err_count" != "0" && "$err_count" != "log yok" ]]; then
        echo "  **UYARI:** Son 24h gateway error sayisi: $err_count"
    fi

    # Disk space critical check
    local disk_pct
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ $disk_pct -ge 90 ]]; then
        echo "  **KRITIK:** Disk %$disk_pct dolu!"
    elif [[ $disk_pct -ge 80 ]]; then
        echo "  **UYARI:** Disk %$disk_pct dolu"
    fi

    # Large sessions check
    local large_sessions
    large_sessions=$(find "$OPENCLAW_DIR/agents" -name "*.jsonl" -size +1M 2>/dev/null | wc -l | tr -d ' ')
    if [[ $large_sessions -gt 0 ]]; then
        echo "  **UYARI:** $large_sessions session >1MB — arsivlenmeli"
    fi

    # Check for email triage (if gog CLI exists)
    if command -v gog &>/dev/null; then
        echo "  Email: gog CLI mevcut, kontrol edilebilir"
    fi

    echo "  Diger acil madde yok."
    echo ""
}

section_patchkit() {
    echo "### 2. PATCHKIT"
    echo ""
    nightly_scan_summary
    echo ""

    # Gateway health detail
    echo "  Gateway: $(gateway_status)"
    echo "  Uptime: $(gateway_uptime)"
    echo "  Son restart: $(gateway_last_restart)"
    echo ""
}

section_goals() {
    echo "### 3. HEDEFLER"
    echo ""
    read_goals
    echo ""
}

section_opportunities() {
    echo "### 4. FIRSATLAR"
    echo ""

    # Scout findings — check for recent research
    local recent_research
    recent_research=$(find "$MEMORY_DIR/research-findings" -name "*.md" -newer "$MEMORY_DIR" -mtime -2 2>/dev/null | wc -l | tr -d ' ')
    if [[ $recent_research -gt 0 ]]; then
        echo "  Son 2 gunde $recent_research yeni arastirma bulgusu"
        find "$MEMORY_DIR/research-findings" -name "*.md" -newer "$MEMORY_DIR" -mtime -2 2>/dev/null | while read -r f; do
            local title
            title=$(head -1 "$f" 2>/dev/null | sed 's/^#\+ //')
            echo "    - $title"
        done
    else
        echo "  Yeni scout bulgusu yok"
    fi

    # Idea bank check
    if [[ -f "$MEMORY_DIR/idea-bank.md" ]]; then
        local idea_count
        idea_count=$(grep -c "^- " "$MEMORY_DIR/idea-bank.md" 2>/dev/null || echo "0")
        echo "  Idea bank: $idea_count fikir"
    fi

    echo ""
}

section_system() {
    echo "### 5. SISTEM"
    echo ""
    echo "  **Gateway:** $(gateway_status) | Uptime: $(gateway_uptime)"
    echo "  **Disk:** $(disk_summary)"
    echo ""
    echo "  **Sessions:**"
    session_sizes
    echo ""
    echo "  **Memory:**"
    memory_stats
    echo ""
    echo "  **Cron:**"
    cron_status
    echo ""
}

section_metrics_summary() {
    echo "### 6. METRIKLER (24h)"
    echo ""
    if [[ -x "$METRICS_SCRIPT" ]]; then
        # Inline compact summary
        local metrics_db="$MEMORY_DIR/metrics.db"
        if [[ -f "$metrics_db" ]]; then
            local task_count
            task_count=$(sqlite3 "$metrics_db" "SELECT COUNT(*) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
            local total_cost
            total_cost=$(sqlite3 "$metrics_db" "SELECT ROUND(SUM(cost_estimate), 4) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');" 2>/dev/null || echo "0")
            local success_rate
            success_rate=$(sqlite3 "$metrics_db" "
                SELECT ROUND(
                    CAST(SUM(CASE WHEN status IN ('SUCCESS','completed','success') THEN 1 ELSE 0 END) AS FLOAT) /
                    NULLIF(COUNT(*), 0) * 100, 0
                ) FROM task_log WHERE ts >= datetime('now', '-24 hours', 'localtime');
            " 2>/dev/null || echo "0")
            echo "  Tasks: $task_count | Basari: ${success_rate:-0}% | Maliyet: \$${total_cost:-0}"
        else
            echo "  Metrics DB henuz olusturulmamis"
        fi
    else
        echo "  metrics.sh bulunamadi"
    fi
    echo ""
}

section_circuit_breaker() {
    echo "### Circuit Breaker Status"
    local cb_script="$SCRIPT_DIR/circuit-breaker.sh"
    if [[ -x "$cb_script" ]]; then
        bash "$cb_script" status 2>/dev/null || echo "- CB data unavailable"
    else
        echo "- Circuit breaker not installed"
    fi
    echo ""
}

section_eval_summary() {
    echo "### Eval Quality Scores (7d)"
    python3 - "$MEMORY_DIR/trajectory-pool.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        raw = json.load(f)
    entries = raw.get("entries", raw) if isinstance(raw, dict) else raw
    scored = [e for e in entries if e.get("eval_score")]
    if not scored:
        print("- No eval data yet")
    else:
        avg = sum(e["eval_score"] for e in scored) / len(scored)
        low = [e for e in scored if e["eval_score"] < 40]
        print(f"- Average score: {avg:.0f}/100 ({len(scored)} evaluated)")
        if low:
            print(f"- Low quality outputs: {len(low)}")
except Exception:
    print("- Eval data unavailable")
PYEOF
    echo ""
}

section_shadow_reviews() {
    echo "### Shadow Agent Reviews"
    local shadow_dir="$MEMORY_DIR/shadow-reviews"
    if [[ -d "$shadow_dir" ]]; then
        local count
        count=$(find "$shadow_dir" -name "*.md" -mtime -7 2>/dev/null | wc -l | tr -d ' ')
        echo "- Reviews this week: $count"
        local latest
        latest=$(find "$shadow_dir" -name "*.md" -mtime -1 2>/dev/null | tail -1)
        if [[ -n "$latest" ]]; then
            echo "- Latest: $(head -1 "$latest")"
        fi
    else
        echo "- Shadow agent system not active"
    fi
    echo ""
}

# --- Midday Sections ---

section_unresolved() {
    echo "### Cozulmemis Maddeler"
    echo ""

    # Check morning briefing for items
    local morning_file="$BRIEFING_DIR/${TODAY}-morning.md"
    if [[ -f "$morning_file" ]]; then
        # Extract KRITIK/UYARI items from morning
        local issues
        issues=$(grep -c "KRITIK\|UYARI" "$morning_file" 2>/dev/null || echo "0")
        if [[ $issues -gt 0 ]]; then
            echo "  Sabah briefing'den $issues acik uyari:"
            grep "KRITIK\|UYARI" "$morning_file" 2>/dev/null | while read -r line; do
                echo "  $line"
            done
        else
            echo "  Sabah briefing'den acik madde yok"
        fi
    else
        echo "  Sabah briefing bulunamadi"
    fi
    echo ""
}

section_new_alerts() {
    echo "### Yeni Uyarilar"
    echo ""

    local gw_status
    gw_status=$(gateway_status)
    if [[ "$gw_status" == *"DOWN"* ]]; then
        echo "  **KRITIK:** Gateway DOWN!"
    else
        echo "  Gateway: $gw_status"
    fi

    local disk_pct
    disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ $disk_pct -ge 85 ]]; then
        echo "  **UYARI:** Disk %$disk_pct"
    fi

    echo ""
}

# --- Evening Sections ---

section_completed_tasks() {
    echo "### Tamamlanan Isler"
    echo ""

    # From metrics
    local metrics_db="$MEMORY_DIR/metrics.db"
    if [[ -f "$metrics_db" ]]; then
        local completed
        completed=$(sqlite3 "$metrics_db" "
            SELECT COUNT(*) FROM task_log
            WHERE date(ts) = date('now', 'localtime')
            AND status IN ('SUCCESS','completed','success');
        " 2>/dev/null || echo "0")
        local failed
        failed=$(sqlite3 "$metrics_db" "
            SELECT COUNT(*) FROM task_log
            WHERE date(ts) = date('now', 'localtime')
            AND status IN ('FAILED','failed','error');
        " 2>/dev/null || echo "0")
        echo "  Bugun: $completed basarili, $failed basarisiz task"
    fi

    # Daily notes check
    local daily_note="$MEMORY_DIR/${TODAY}.md"
    if [[ -f "$daily_note" ]]; then
        echo "  Daily note mevcut: $daily_note"
    fi
    echo ""
}

section_pending_items() {
    echo "### Bekleyen Maddeler"
    echo ""

    # Check for unresolved warnings from today
    local briefings_today
    briefings_today=$(find "$BRIEFING_DIR" -name "${TODAY}-*" 2>/dev/null)
    local total_warnings=0
    for bf in $briefings_today; do
        local w
        w=$(grep -c "KRITIK\|UYARI" "$bf" 2>/dev/null | tail -1 || echo "0")
        w=$(echo "$w" | tr -d '[:space:]')
        total_warnings=$((total_warnings + w))
    done

    if [[ $total_warnings -gt 0 ]]; then
        echo "  Bugunden $total_warnings cozulmemis uyari"
    else
        echo "  Acik uyari yok"
    fi

    # Gateway status
    echo "  Gateway: $(gateway_status)"
    echo ""
}

section_nightly_eta() {
    echo "### Nightly Scan"
    echo ""

    # Check crontab for nightly-scan
    local scan_cron
    scan_cron=$(crontab -l 2>/dev/null | grep -i "nightly-scan" | head -1 || echo "")
    if [[ -n "$scan_cron" ]]; then
        local scan_time
        scan_time=$(echo "$scan_cron" | awk '{print $2":"$1}')
        echo "  Planli: $scan_time"
    else
        echo "  Nightly scan cron bulunamadi"
    fi

    nightly_scan_summary
    echo ""
}

# --- Briefing Composers ---

compose_morning() {
    local output="$BRIEFING_DIR/${TODAY}-morning.md"

    {
        echo "# Oracle Sabah Briefing"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_priority
        hr
        section_patchkit
        hr
        section_goals
        hr
        section_opportunities
        hr
        section_system
        hr
        section_metrics_summary
        hr
        section_circuit_breaker
        section_eval_summary
        section_shadow_reviews
        hr
        echo ""
        echo "*Oracle briefing tamamlandi — $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Morning briefing saved: $output"
}

compose_midday() {
    local output="$BRIEFING_DIR/${TODAY}-midday.md"

    {
        echo "# Oracle Ogle Check-in"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_unresolved
        hr
        section_new_alerts
        hr
        echo "### Quick Stats"
        echo ""
        echo "  Gateway: $(gateway_status) | Uptime: $(gateway_uptime)"
        echo "  Disk: $(disk_summary)"
        section_metrics_summary
        hr
        echo ""
        echo "*Oracle check-in tamamlandi — $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Midday briefing saved: $output"
}

compose_evening() {
    local output="$BRIEFING_DIR/${TODAY}-evening.md"

    {
        echo "# Oracle Aksam Review"
        echo "## $TODAY $NOW"
        echo ""
        hr
        section_completed_tasks
        hr
        section_pending_items
        hr
        section_goals
        hr
        section_nightly_eta
        hr
        section_system
        hr
        section_circuit_breaker
        section_eval_summary
        section_shadow_reviews
        hr
        echo ""
        echo "*Oracle aksam review tamamlandi — $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Evening briefing saved: $output"
}

compose_custom() {
    local topic="${1:?Konu belirtilmeli}"
    local output="$BRIEFING_DIR/${TODAY}-custom-$(echo "$topic" | tr ' ' '-' | tr '[:upper:]' '[:lower:]').md"

    {
        echo "# Oracle Custom Briefing: $topic"
        echo "## $TODAY $NOW"
        echo ""
        hr

        case "$topic" in
            gateway|gw)
                echo "### Gateway Detay Raporu"
                echo ""
                echo "  Status: $(gateway_status)"
                echo "  Uptime: $(gateway_uptime)"
                echo "  Errors (24h): $(gateway_errors_24h)"
                echo "  Son restart: $(gateway_last_restart)"
                echo ""
                echo "  **Port Kontrolu:**"
                if lsof -i :28643 -P 2>/dev/null | grep -q LISTEN; then
                    echo "    28643: LISTEN"
                else
                    echo "    28643: KAPALI"
                fi
                if lsof -i :28645 -P 2>/dev/null | grep -q LISTEN; then
                    echo "    28645: LISTEN"
                else
                    echo "    28645: KAPALI"
                fi
                echo ""
                echo "  **Son 20 Log Satiri:**"
                echo '```'
                tail -20 "$OPENCLAW_DIR/logs/gateway.log" 2>/dev/null || echo "Log bulunamadi"
                echo '```'
                ;;

            patchkit|patch)
                echo "### Patchkit Detay Raporu"
                echo ""
                nightly_scan_summary
                echo ""
                echo "  **Patch Listesi:**"
                find "$HOME/.agent-system/my-patches/manual-patches" -name "PR-*.sh" -o -name "FIX-*.sh" 2>/dev/null | sort | while read -r f; do
                    echo "    $(basename "$f")"
                done
                ;;

            cost|maliyet)
                echo "### Maliyet Raporu"
                echo ""
                if [[ -x "$METRICS_SCRIPT" ]]; then
                    "$METRICS_SCRIPT" cost 7 2>/dev/null || echo "  Metrik verisi yok"
                else
                    echo "  metrics.sh bulunamadi"
                fi
                ;;

            goals|hedef)
                echo "### Hedef Detay"
                echo ""
                read_goals
                ;;

            disk)
                echo "### Disk Detay Raporu"
                echo ""
                echo "  **Genel:** $(disk_summary)"
                echo ""
                echo "  **Buyuk Dizinler:**"
                du -sh "$OPENCLAW_DIR" 2>/dev/null | awk '{print "    ~/.agent-system: "$1}'
                du -sh "$CLAWD_DIR" 2>/dev/null | awk '{print "    ~/.agent-evolution: "$1}'
                du -sh "$OPENCLAW_DIR/my-patches" 2>/dev/null | awk '{print "    ~/.agent-evolution/my-patches: "$1}'
                du -sh "$OPENCLAW_DIR/session-archive" 2>/dev/null | awk '{print "    ~/.agent-evolution/session-archive: "$1}'
                du -sh "$OPENCLAW_DIR/logs" 2>/dev/null | awk '{print "    ~/.agent-evolution/logs: "$1}'
                echo ""
                echo "  **Buyuk Dosyalar (>50MB):**"
                find "$HOME" -maxdepth 4 -size +50M -not -path "*/Library/*" -not -path "*/.Trash/*" -not -path "*/node_modules/*" 2>/dev/null | head -10 | while read -r f; do
                    local sz
                    sz=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
                    echo "    $sz  $f"
                done
                ;;

            memory|hafiza)
                echo "### Memory Detay"
                echo ""
                memory_stats
                echo ""
                echo "  **Kategoriler:**"
                for dir in knowledge reflections decisions learnings conversations distilled; do
                    local cnt
                    cnt=$(find "$MEMORY_DIR/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                    echo "    $dir: $cnt dosya"
                done
                echo ""
                echo "  **Son Yazilanlar (24h):**"
                find "$MEMORY_DIR" -maxdepth 2 -name "*.md" -newer "$MEMORY_DIR" -mtime -1 2>/dev/null | head -10 | while read -r f; do
                    echo "    $(basename "$f")"
                done
                ;;

            *)
                echo "### Genel Durum: $topic"
                echo ""
                echo "  Taninan konular: gateway, patchkit, cost, goals, disk, memory"
                echo "  '$topic' icin ozel handler yok — genel bilgiler gosteriliyor."
                echo ""
                section_system
                ;;
        esac

        hr
        echo ""
        echo "*Oracle custom briefing tamamlandi — $(date '+%H:%M:%S')*"
    } | tee "$output"

    log "Custom briefing saved: $output"
}

# --- Send to Telegram ---
send_briefing() {
    local latest
    latest=$(find "$BRIEFING_DIR" -name "${TODAY}-*" -type f 2>/dev/null | sort | tail -1)

    if [[ -z "$latest" ]]; then
        echo "Bugun briefing bulunamadi"
        exit 1
    fi

    if command -v hachi-send &>/dev/null; then
        echo "Gonderiliyor: $(basename "$latest")"
        hachi-send < "$latest"
        log "Briefing sent via hachi-send: $latest"
        echo "Gonderildi."
    else
        echo "hachi-send bulunamadi. Manuel gonderim:"
        echo "  cat $latest | pbcopy"
    fi
}

# --- Help ---
cmd_help() {
    cat <<'HELP'
briefing.sh — Tri-phase Daily Briefing System

Kullanim:
  morning              Sabah briefing (08:00)
  midday               Ogle check-in (13:00)
  evening              Aksam review (21:00)
  custom <topic>       On-demand briefing

Custom Konular:
  gateway/gw           Gateway detay raporu
  patchkit/patch       Patchkit durumu
  cost/maliyet         Maliyet raporu
  goals/hedef          Hedef takibi
  disk                 Disk analizi
  memory/hafiza        Memory istatistikleri

Opsiyonlar:
  --send               Son briefing'i Telegram'a gonder (hachi-send gerekli)
  --help, -h           Bu yardim mesaji

Briefing'ler kaydedilir: ~/.agent-evolution/memory/briefings/YYYY-MM-DD-{morning,midday,evening}.md

Cron Ornegi:
  0 8 * * *   ~/.agent-evolution/scripts/briefing.sh morning
  0 13 * * *  ~/.agent-evolution/scripts/briefing.sh midday
  0 21 * * *  ~/.agent-evolution/scripts/briefing.sh evening
HELP
}

# --- Main ---
main() {
    ensure_dirs

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    local start_ts
    start_ts=$(date +%s)

    case "$cmd" in
        morning)    compose_morning ;;
        midday)     compose_midday ;;
        evening)    compose_evening ;;
        custom)     compose_custom "$@" ;;
        --send)     send_briefing ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Bilinmeyen komut: $cmd"
            echo "Kullanim icin: briefing.sh help"
            exit 1
            ;;
    esac

    # Record metrics + blackboard
    local duration=$(( $(date +%s) - start_ts ))
    sqlite3 "$METRICS_DB" \
        "INSERT OR IGNORE INTO metrics (agent,metric,value,tags,timestamp) VALUES ('briefing','briefing_generated',1,'phase:$cmd',datetime('now'));" 2>/dev/null || true
    bash "$BLACKBOARD_SCRIPT" set "briefing:last_run" "$(date +%s)" 2>/dev/null || true
}

main "$@"
