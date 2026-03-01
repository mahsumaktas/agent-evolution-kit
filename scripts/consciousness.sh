#!/usr/bin/env bash
# STANDBY: Self-awareness rutini — manual kullanim. Gelecekte weekly-cycle entegrasyonu.
# Oracle Consciousness Snapshot — Compaction-proof durum dosyasi
# Her onemli degisiklikte calistirilir, tek dosya okuyunca Oracle'in
# tum durumunu hatirlamasini saglar.
#
# Kullanim:
#   consciousness.sh              # Snapshot olustur
#   consciousness.sh --view       # Mevcut snapshot'i goster

set -euo pipefail

CONSCIOUSNESS="$HOME/clawd/memory/consciousness.md"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

SESSION_STATE="$HOME/clawd/SESSION-STATE.md"
AGENTS_MD="$HOME/clawd/AGENTS.md"
VERSION_DIR="$HOME/clawd/memory/prompt-versions"

if [[ "${1:-}" == "--view" ]]; then
    cat "$CONSCIOUSNESS" 2>/dev/null || echo "Henuz consciousness snapshot yok"
    exit 0
fi

if [[ "${1:-}" == "--session-state" ]]; then
    # SESSION-STATE.md'ye timestamp delta update
    if [[ -f "$SESSION_STATE" ]]; then
        sed -i '' "s/^# SESSION-STATE — .*/# SESSION-STATE — $(date '+%Y-%m-%d %H:%M')/" "$SESSION_STATE"
        echo "SESSION-STATE.md timestamp guncellendi"
    fi
    exit 0
fi

if [[ "${1:-}" == "--pre-compaction" ]]; then
    # Pre-compaction: consciousness + session-state + prompt version
    echo "Pre-compaction flush basladi..."
    # 1. Normal consciousness snapshot
    # (devam eder asagiya)
    # 2. Prompt version snapshot
    if [[ -d "$VERSION_DIR" ]]; then
        "$HOME/clawd/scripts/evolve-prompt.sh" --dry-run 2>/dev/null || true
    fi
    echo "Pre-compaction flush tamamlandi"
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Kullanim: consciousness.sh [--view|--session-state|--pre-compaction|--help]"
    echo "  (default):        Full consciousness snapshot"
    echo "  --session-state:  SESSION-STATE.md timestamp guncelle"
    echo "  --pre-compaction: Compaction oncesi tam flush"
    exit 0
fi

# === GATHER LIVE STATE ===

# Gateway
GW_PID=$(pgrep -f agent-system 2>/dev/null | head -1 || echo "?")
GW_PORT=$(lsof -i :28643 -P 2>/dev/null | grep -c LISTEN || echo "0")

# Disk
DISK_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')

# Crons
CRON_COUNT=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')

# Patchkit
PATCH_ACTIVE=$(grep -c '^[0-9]' "$HOME/agent-system-patchkit/pr-patches.conf" 2>/dev/null || echo "?")
PATCH_BASE=$(grep -m1 'v20' "$HOME/agent-system-patchkit/pr-patches.conf" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")

# Tools
TOOL_COUNT=$(python3 -c "import json; print(len(json.load(open('$HOME/clawd/tools/catalog.json')).get('tools',[])))" 2>/dev/null || echo "0")

# Trajectory
TRAJ_COUNT=$(python3 -c "import json; print(len(json.load(open('$HOME/clawd/memory/trajectory-pool.json')).get('entries',[])))" 2>/dev/null || echo "0")

# Bridge calls today
TODAY=$(date +%Y%m%d)
BRIDGE_TODAY=$(find "$HOME/clawd/memory/bridge-logs" -name "${TODAY}*" 2>/dev/null | wc -l | tr -d ' ')

# Cost today
COST_TODAY=$(python3 -c "
import json
from datetime import datetime
total = 0
try:
    with open('$HOME/clawd/memory/cost-log.jsonl') as f:
        for line in f:
            e = json.loads(line.strip())
            ts = e.get('ts','')
            if '$(date +%Y-%m-%d)' in ts:
                total += float(e.get('cost',0))
except: pass
print(f'{total:.4f}')
" 2>/dev/null || echo "?")

# Knowledge
KNOW_COUNT=$(find "$HOME/clawd/memory/knowledge" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

# Last evolution
LAST_EVOLVE=$(grep "^## Iterasyon\|^## Prompt Evolution" "$HOME/clawd/memory/evolution-log.md" 2>/dev/null | tail -1 || echo "yok")

# Predictions pending
PRED_COUNT=$(find "$HOME/clawd/memory/predictions" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

# === WRITE CONSCIOUSNESS ===
cat > "$CONSCIOUSNESS" << EOF
# Oracle Consciousness Snapshot
> Auto-generated: $TIMESTAMP
> Compaction sonrasi bu dosyayi oku — tum sistemi hatirla

## Sistem Durumu
- Gateway PID: $GW_PID | Port 28643: $([[ "$GW_PORT" -gt 0 ]] && echo "LISTEN" || echo "DOWN")
- Disk: ${DISK_PCT}%
- Cron: $CRON_COUNT aktif
- Patchkit: $PATCH_ACTIVE patch, base $PATCH_BASE

## Oracle Metrikleri
- Trajectory pool: $TRAJ_COUNT kayit
- Generated tools: $TOOL_COUNT
- Knowledge base: $KNOW_COUNT dosya
- Bridge calls (bugun): $BRIDGE_TODAY
- Cost (bugun): \$$COST_TODAY
- Predictions: $PRED_COUNT dosya
- Son evolution: $LAST_EVOLVE

## Aktif Scriptler
| Script | Gorevi |
|--------|--------|
| bridge.sh | Claude CLI koprusu (identity injection, cost logging) |
| tool-gen.sh | 5 adimli tool uretim pipeline |
| research.sh | Otonom arastirma (auto/topic/trend/gap) |
| predict.sh | Tahmin motoru (weekly/task/risk/opportunity) |
| system-check.sh | Sistem durumu (7 mod) |
| weekly-cycle.sh | Haftalik 6 adimli evolution cycle (Pazar 22:00) |
| daily-check.sh | Gunluk hizli check (03:00) |
| evolve-prompt.sh | Trajectory → prompt update pipeline |
| cost-report.sh | Maliyet ozeti (model/caller/period bazinda) |
| cron-watchdog.sh | Cron health tracking + fail alert |
| memory-index.sh | Memory dosya haritasi (index.json) |
| consciousness.sh | Bu dosyayi olusturan script |

## Cognitive Memory
- **Version:** v3.2 (correction tracker + resonance check + mood signal + enhanced decay)
- **Plugin:** /opt/homebrew/lib/node_modules/agent-system/extensions/memory-lancedb/
- **DB:** ~/.agent-evolution/memory/lancedb/
- **Correction'lar:** decay=0, kalici, enforced RAG'da <correction-warnings> ile inject
- **Mood:** Transient (persist yok), <user-mood> tag ile inject
- **Prompt Versions:** memory/prompt-versions/ (rollback: evolve-prompt.sh --rollback vXXX)

## Kritik Dosyalar
- Identity prompt: scripts/identity-prompt.txt
- Trajectory: memory/trajectory-pool.json
- Evolution log: memory/evolution-log.md
- Cost log: memory/cost-log.jsonl
- Memory index: memory/index.json
- Cron health: memory/cron-health.json
- Tool catalog: tools/catalog.json
- Prompt versions: memory/prompt-versions/

## Son Ogrenilenler
$(python3 -c "
import json
try:
    with open('$HOME/clawd/memory/trajectory-pool.json') as f:
        pool = json.load(f)
    for e in pool.get('entries',[])[-3:]:
        for l in e.get('lessons',[]):
            print(f'- {l}')
except: print('- (trajectory bos)')
" 2>/dev/null)

## Haftalik Cycle Durumu
- Sonraki calisma: Pazar 22:00 (crontab)
- Adimlar: Watchdog → System Check → Research → Predict → Prompt Evolution → Memory Index
EOF

echo "Consciousness snapshot guncellendi: $CONSCIOUSNESS"
