#!/usr/bin/env bash
# Oracle Predictive Engine — Gecmis deneyimlerden gelecek tahmini
# Trajectory pool, reflections ve evolution log'u analiz eder.
#
# Kullanim:
#   predict.sh --weekly          # Haftalik tahmin raporu
#   predict.sh --task "cve scan" # Belirli gorev tipi tahmini
#   predict.sh --risk            # Risk analizi
#   predict.sh --opportunity     # Firsat tespiti

set -euo pipefail

BRIDGE="$HOME/clawd/scripts/bridge.sh"
TRAJECTORY="$HOME/clawd/memory/trajectory-pool.json"
EVOLUTION_LOG="$HOME/clawd/memory/evolution-log.md"
REFLECTIONS_DIR="$HOME/clawd/memory/reflections"
KNOWLEDGE_DIR="$HOME/clawd/memory/knowledge"
PREDICT_DIR="$HOME/clawd/memory/predictions"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[predict]${NC} $1" >&2; }
step() { echo -e "${CYAN}[predict]${NC} === $1 ===" >&2; }

MODE="weekly"
TASK_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --weekly)      MODE="weekly"; shift;;
        --task)        MODE="task"; TASK_TYPE="$2"; shift 2;;
        --risk)        MODE="risk"; shift;;
        --opportunity) MODE="opportunity"; shift;;
        --help|-h)
            echo "Kullanim: predict.sh [--weekly | --task \"tip\" | --risk | --opportunity]"
            exit 0;;
        *) shift;;
    esac
done

mkdir -p "$PREDICT_DIR"

# === GATHER DATA ===
step "VERI TOPLAMA"

# Trajectory stats
TRAJECTORY_STATS=$(python3 -c "
import json, os
from collections import Counter, defaultdict
from datetime import datetime, timedelta

try:
    with open('$TRAJECTORY') as f:
        pool = json.load(f)
    entries = pool.get('entries', [])
except:
    entries = []

if not entries:
    print('TRAJECTORY_EMPTY=true')
    print('TOTAL_TASKS=0')
    exit()

total = len(entries)
success = sum(1 for e in entries if e.get('result') == 'SUCCESS')
failed = sum(1 for e in entries if e.get('result') == 'FAILED')
partial = total - success - failed

# By agent
agent_stats = defaultdict(lambda: {'success': 0, 'total': 0, 'tokens': 0})
for e in entries:
    agent = e.get('agent', 'unknown')
    agent_stats[agent]['total'] += 1
    agent_stats[agent]['tokens'] += e.get('tokens_used', 0)
    if e.get('result') == 'SUCCESS':
        agent_stats[agent]['success'] += 1

# By task type
type_stats = defaultdict(lambda: {'success': 0, 'total': 0})
for e in entries:
    tt = e.get('task_type', 'unknown')
    type_stats[tt]['total'] += 1
    if e.get('result') == 'SUCCESS':
        type_stats[tt]['success'] += 1

# Failure reasons
fail_reasons = Counter(e.get('failure_reason', 'unknown') for e in entries if e.get('result') == 'FAILED')

print(f'TOTAL_TASKS={total}')
print(f'SUCCESS_RATE={success/total*100:.1f}')
print(f'FAILED={failed}')
print(f'PARTIAL={partial}')
print()
print('AGENT_STATS:')
for agent, stats in sorted(agent_stats.items()):
    rate = stats['success']/stats['total']*100 if stats['total'] > 0 else 0
    print(f'  {agent}: {rate:.0f}% basari ({stats[\"total\"]} gorev, {stats[\"tokens\"]:,} token)')
print()
print('TASK_TYPE_STATS:')
for tt, stats in sorted(type_stats.items()):
    rate = stats['success']/stats['total']*100 if stats['total'] > 0 else 0
    print(f'  {tt}: {rate:.0f}% basari ({stats[\"total\"]} gorev)')
print()
print('TOP_FAILURES:')
for reason, count in fail_reasons.most_common(5):
    print(f'  {reason}: {count}x')
" 2>/dev/null) || TRAJECTORY_STATS="TRAJECTORY_EMPTY=true"

# Reflection count
REFLECTION_COUNT=$(find "$REFLECTIONS_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

# Knowledge count
KNOWLEDGE_COUNT=$(find "$KNOWLEDGE_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

log "Trajectory: $(echo "$TRAJECTORY_STATS" | head -1)"
log "Reflections: $REFLECTION_COUNT dosya"
log "Knowledge: $KNOWLEDGE_COUNT dosya"

# === GENERATE PREDICTION ===
step "TAHMIN URETIMI — $MODE"

PREDICTION_PROMPT="Sen Oracle'in Predictive Engine'isin. Gecmis verileri analiz edip gelecek tahmini yapiyorsun.

MOD: $MODE
$([ -n "$TASK_TYPE" ] && echo "GOREV TIPI: $TASK_TYPE")

MEVCUT VERILER:
$TRAJECTORY_STATS

Reflection sayisi: $REFLECTION_COUNT
Knowledge base boyutu: $KNOWLEDGE_COUNT dosya

GOREV ($MODE):
$(case $MODE in
    weekly)
        echo "Haftalik tahmin raporu hazirla:
1. Gelecek hafta hangi gorev tipleri basarili olacak? (confidence %)
2. Hangi agent'lar risk altinda? (basari orani dusuk olanlar)
3. Token tuketimi trendi (artis/azalis tahmini)
4. En onemli 3 iyilestirme firsati
5. Proaktif oneriler (User'a sunulacak)";;
    task)
        echo "Bu gorev tipi icin tahmin yap: $TASK_TYPE
1. Basari olasiligi (%) ve guvenirligi
2. Beklenen sure ve token tuketimi
3. Potansiyel riskler
4. Onerilen strateji
5. En iyi model secimi";;
    risk)
        echo "Risk analizi yap:
1. En yuksek riskli 3 alan (agent/gorev/sistem)
2. Her risk icin olasilik ve etki degerlendirmesi
3. Onleyici tedbirler
4. Acil mudahale gerektiren durumlar
5. Sistem sagligi genel degerlendirmesi";;
    opportunity)
        echo "Firsat analizi yap:
1. Mevcut verilerdeki gorunmeyen firsatlar
2. Yeni tool onerisi (hangi araclari uretmeliyiz?)
3. Yeni otomasyon firsatlari (hangi isler otomatiklestirilebilir?)
4. User'un kariyeri icin stratejik firsatlar
5. Oracle'in kendini gelistirmesi icin firsatlar";;
esac)

FORMAT: Markdown, kisa ve somut"

PREDICTION=$(bash "$BRIDGE" --analyze --text --silent "$PREDICTION_PROMPT" 2>/dev/null) || {
    log "Tahmin uretimi icin yeterli veri yok"
    PREDICTION="# Tahmin Raporu - $(date +%Y-%m-%d)

Trajectory pool'da yeterli veri yok. Sistem yeni kuruldu.
Veri birikimi icin en az 1 hafta bekle.

## Ilk Oneriler
- Agent'lari aktif kullanmaya basla
- Gorevleri trajectory pool'a kaydetmeyi unutma
- Ilk haftalik cycle'i Pazar gunu calistir"
fi

# === SAVE ===
PREDICT_FILE="$PREDICT_DIR/$(date +%Y-%m-%d)-${MODE}.md"
echo "$PREDICTION" > "$PREDICT_FILE"

log "Tahmin kaydedildi: $PREDICT_FILE"

# === OUTPUT ===
echo ""
echo "$PREDICTION"
