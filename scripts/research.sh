#!/usr/bin/env bash
# Oracle Autonomous Research Engine — Otonom arastirma sistemi
# Oracle bu script ile surekli kendini gelistirmek icin arastirma yapar.
#
# Kullanim:
#   research.sh --topic "AI self-evolution"      # Belirli konu
#   research.sh --auto                           # Otomatik konu secimi
#   research.sh --trend                          # Teknoloji trend taramasi
#   research.sh --gap-analysis                   # Bilgi boslugu analizi

set -euo pipefail

BRIDGE="$HOME/clawd/scripts/bridge.sh"
KNOWLEDGE_DIR="$HOME/clawd/memory/knowledge"
TRAJECTORY="$HOME/clawd/memory/trajectory-pool.json"
REFLECTIONS_DIR="$HOME/clawd/memory/reflections"
RESEARCH_LOG="$HOME/clawd/memory/research-log.md"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[research]${NC} $1" >&2; }
step() { echo -e "${CYAN}[research]${NC} === $1 ===" >&2; }

# === ARGS ===
MODE="topic"
TOPIC=""
DEPTH="standard"  # standard | deep

while [[ $# -gt 0 ]]; do
    case $1 in
        --topic) MODE="topic"; TOPIC="$2"; shift 2;;
        --auto)  MODE="auto"; shift;;
        --trend) MODE="trend"; shift;;
        --gap-analysis) MODE="gap"; shift;;
        --deep)  DEPTH="deep"; shift;;
        --help|-h)
            echo "Kullanim: research.sh [--topic \"konu\" | --auto | --trend | --gap-analysis] [--deep]"
            exit 0;;
        *) TOPIC="$1"; shift;;
    esac
done

mkdir -p "$KNOWLEDGE_DIR"

# === AUTO TOPIC SELECTION ===
if [[ "$MODE" == "auto" ]]; then
    step "OTOMATIK KONU SECIMI"
    log "Trajectory pool ve reflections analiz ediliyor..."

    TOPIC=$(python3 -c "
import json, os, glob

# Analyze reflections for recurring failures
reflections = []
for f in glob.glob('$REFLECTIONS_DIR/*/*.md'):
    with open(f) as fh:
        reflections.append(fh.read())

# Analyze trajectory pool for weak areas
try:
    with open('$TRAJECTORY') as f:
        pool = json.load(f)
    entries = pool.get('entries', [])
    failed = [e for e in entries if e.get('result') == 'FAILED']
    # Find most common failure types
    fail_types = {}
    for e in failed:
        t = e.get('task_type', 'unknown')
        fail_types[t] = fail_types.get(t, 0) + 1
    if fail_types:
        worst = max(fail_types, key=fail_types.get)
        print(f'En cok basarisiz gorev tipi: {worst} — iyilestirme yontemleri arastir')
    elif reflections:
        print('Agent reflections incelemesi — tekrarlayan sorunlar ve cozumleri')
    else:
        print('AI agent self-improvement ve autonomous tool generation guncel teknikler')
except:
    print('AI agent self-improvement ve autonomous tool generation guncel teknikler')
" 2>/dev/null)

    log "Secilen konu: $TOPIC"
fi

if [[ "$MODE" == "trend" ]]; then
    TOPIC="Son 1 haftanin en onemli AI/ML gelismeleri, yeni araclar, yeni frameworkler, User'un kariyerine etkisi"
fi

if [[ "$MODE" == "gap" ]]; then
    step "BILGI BOSLUGU ANALIZI"
    TOPIC=$(python3 -c "
import json, os, glob

# Check what knowledge exists
existing = set()
for f in glob.glob('$KNOWLEDGE_DIR/*.md'):
    existing.add(os.path.basename(f).replace('.md',''))

# Define expected knowledge areas
expected = [
    'ai-agent-frameworks', 'prompt-engineering', 'mcp-protocol',
    'claude-code-api', 'typescript-best-practices', 'python-automation',
    'devops-patterns', 'security-best-practices', 'freelance-strategies',
    'twitter-growth', 'tech-trends-2026'
]

missing = [e for e in expected if e not in existing]
if missing:
    print(f'Eksik bilgi alanlari: {', '.join(missing[:3])} — bunlari arastir')
else:
    print('Mevcut bilgi alanlarini guncelle ve derinlestir')
" 2>/dev/null)

    log "Gap analizi sonucu: $TOPIC"
fi

[[ -z "$TOPIC" ]] && { echo "Konu belirtilmedi"; exit 1; }

# === RESEARCH ===
step "ARASTIRMA BASLADI"
log "Konu: $TOPIC"
log "Derinlik: $DEPTH"

BRIDGE_MODE="--research"
[[ "$DEPTH" == "standard" ]] && BRIDGE_MODE="--analyze"

RESEARCH_PROMPT="Sen Oracle'in Autonomous Research Engine'isin. Amacin: Oracle'i ve User'u daha guclu kilmak.

ARASTIRMA KONUSU: $TOPIC

GOREV:
1. Bu konuda kapsamli arastirma yap (web search, docs, GitHub)
2. En onemli 5-10 bulguyu ozetle
3. Her bulgu icin SOMUT aksiyon onerisi yaz
4. User'un durumuna (Istanbul, Technical COO hedefi, freelancing) baglantisi nedir?

FORMAT:
# Arastirma: [konu]
Tarih: [bugunun tarihi]

## Ozet
[2-3 cumle]

## Bulgular
1. **[bulgu basligi]**
   - Detay: [aciklama]
   - Kaynak: [URL veya referans]
   - Aksiyon: [ne yapilmali]

## Oneriler
- [somut oneri 1]
- [somut oneri 2]
- [somut oneri 3]

## Oracle Icin Cikarimlar
- [Oracle'in kendini nasil gelistirebilecegi]
"

RESULT=$(bash "$BRIDGE" $BRIDGE_MODE --text --silent "$RESEARCH_PROMPT" 2>/dev/null) || {
    echo "Arastirma basarisiz" >&2
    exit 1
}

# === SAVE FINDINGS ===
step "BULGULAR KAYDEDILIYOR"

SAFE_TOPIC=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c50)
FINDING_FILE="$KNOWLEDGE_DIR/$(date +%Y-%m-%d)-${SAFE_TOPIC}.md"

echo "$RESULT" > "$FINDING_FILE"
log "Bulgular kaydedildi: $FINDING_FILE"

# === UPDATE RESEARCH LOG ===
TIMESTAMP=$(date +%Y-%m-%d)
cat >> "$RESEARCH_LOG" << EOF

## $TIMESTAMP — $TOPIC
- **Mod:** $MODE
- **Derinlik:** $DEPTH
- **Dosya:** $FINDING_FILE
- **Durum:** TAMAMLANDI
EOF

log "Research log guncellendi"

# === OUTPUT SUMMARY ===
echo ""
echo "=== ARASTIRMA TAMAMLANDI ==="
echo "Konu:   $TOPIC"
echo "Dosya:  $FINDING_FILE"
echo "Log:    $RESEARCH_LOG"
echo ""
echo "$RESULT" | head -20
