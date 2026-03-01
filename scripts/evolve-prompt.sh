#!/usr/bin/env bash
# Oracle Prompt Evolution — Veriden ogrenerek identity prompt'u gunceller
# Kullanim:
#   evolve-prompt.sh              # Analiz yap, oneri goster
#   evolve-prompt.sh --apply      # Analiz yap ve uygula
#   evolve-prompt.sh --dry-run    # Sadece analiz, degisiklik yapma

set -euo pipefail

IDENTITY_PROMPT="$HOME/clawd/scripts/identity-prompt.txt"
AGENTS_MD="$HOME/clawd/AGENTS.md"
TRAJECTORY="$HOME/clawd/memory/trajectory-pool.json"
COST_LOG="$HOME/clawd/memory/cost-log.jsonl"
RESEARCH_LOG="$HOME/clawd/memory/research-log.md"
EVOLUTION_LOG="$HOME/clawd/memory/evolution-log.md"
KNOWLEDGE_DIR="$HOME/clawd/memory/knowledge/hot"
BACKUP_DIR="$HOME/clawd/memory/prompt-backups"
VERSION_DIR="$HOME/clawd/memory/prompt-versions"
OPENCLAW_LOG="$HOME/.agent-system/logs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[evolve]${NC} $1" >&2; }
step() { echo -e "${CYAN}[evolve]${NC} === $1 ===" >&2; }

MODE="analyze"
while [[ $# -gt 0 ]]; do
    case $1 in
        --apply)    MODE="apply"; shift;;
        --dry-run)  MODE="dry-run"; shift;;
        --rollback) MODE="rollback"; shift;;
        --help|-h)
            echo "Kullanim: evolve-prompt.sh [--apply|--dry-run|--rollback vXXX]"
            echo "  (default):    Analiz yap, oneri goster"
            echo "  --apply:      Analiz yap ve prompt'u guncelle"
            echo "  --dry-run:    Sadece analiz, degisiklik yapma"
            echo "  --rollback:   Belirtilen versiyona geri don"
            exit 0;;
        *) shift;;
    esac
done

# === STEP 0: VERSION SNAPSHOT ===
step "0/5 VERSION SNAPSHOT"

mkdir -p "$VERSION_DIR"
NEXT_VER=$(printf "v%03d" "$(( $(ls "$VERSION_DIR"/v*.json 2>/dev/null | wc -l | tr -d ' ') + 1 ))")
python3 << SNAPEOF
import json, os, re
from datetime import datetime

agents = ""
try:
    with open(os.path.expanduser("~/.agent-evolution/AGENTS.md")) as f:
        agents = f.read()
except: pass

# Extract key rule sections
sections = {}
for section_name in ["CORRECTION CAPTURE", "DOĞRULAMA KURALI", "TARİH KURALI", "TEMEL KURALLAR"]:
    pattern = rf"## {re.escape(section_name)}.*?\n(.*?)(?=\n## |\Z)"
    m = re.search(pattern, agents, re.DOTALL)
    if m:
        sections[section_name] = m.group(1).strip()

ver = {
    "version": "$NEXT_VER",
    "timestamp": datetime.now().isoformat(),
    "source": "evolve-prompt.sh",
    "sections": sections,
    "agentsMdHash": str(hash(agents))[:12],
}

outpath = os.path.expanduser(f"~/.agent-evolution/memory/prompt-versions/${NEXT_VER}.json")
with open(outpath, "w") as f:
    json.dump(ver, f, indent=2, ensure_ascii=False)
print(f"Version snapshot: {outpath}")
SNAPEOF

log "Prompt version $NEXT_VER kaydedildi"

# === STEP 0.5: SCAN CORRECTION EVENTS ===
step "0.5/5 CORRECTION EVENT TARAMA"

# Scan AgentSystem logs for recent corrections (v3.2 event emit)
CORRECTION_COUNT=0
CORRECTIONS_FOUND=$(find "$OPENCLAW_LOG" -name "*.log" -mtime -1 2>/dev/null | xargs grep -l "CORRECTION stored" 2>/dev/null || true)
if [[ -n "$CORRECTIONS_FOUND" ]]; then
    CORRECTION_COUNT=$(echo "$CORRECTIONS_FOUND" | xargs grep -c "CORRECTION stored" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || echo "0")
    log "Son 24 saatte $CORRECTION_COUNT correction event bulundu"
    echo "$CORRECTIONS_FOUND" | xargs grep "CORRECTION stored" 2>/dev/null | tail -5 | while read -r line; do
        echo "  → $(echo "$line" | sed 's/.*CORRECTION stored — "//' | sed 's/".*//')"
    done
else
    log "Son 24 saatte correction event yok"
fi

# === STEP 1: GATHER SIGNALS ===
step "1/5 SINYAL TOPLAMA"

# Trajectory lessons
TRAJECTORY_LESSONS=$(python3 -c "
import json
try:
    with open('$TRAJECTORY') as f:
        pool = json.load(f)
    entries = pool.get('entries', [])
    lessons = []
    for e in entries:
        for l in e.get('lessons', []):
            lessons.append(l)
    if lessons:
        print('TRAJECTORY DERSLERI:')
        for l in lessons[-10:]:  # son 10 ders
            print(f'- {l}')
    else:
        print('Trajectory dersi yok (pool bos veya lesson kaydi yok)')
except Exception as ex:
    print(f'Trajectory okunamadi: {ex}')
" 2>/dev/null)

# Cost patterns
COST_PATTERNS=$(python3 -c "
import json
from collections import defaultdict
try:
    costs = defaultdict(lambda: {'calls': 0, 'cost': 0})
    with open('$COST_LOG') as f:
        for line in f:
            e = json.loads(line.strip())
            m = e.get('model','?')
            costs[m]['calls'] += 1
            costs[m]['cost'] += float(e.get('cost',0))
    print('MALIYET PATTERN:')
    for m, s in costs.items():
        avg = s['cost']/s['calls'] if s['calls'] > 0 else 0
        print(f'- {m}: {s[\"calls\"]} cagri, ort \${avg:.4f}/cagri')
except:
    print('Cost log yok veya okunamadi')
" 2>/dev/null)

# Recent research topics
RESEARCH_TOPICS=$(python3 -c "
import re
try:
    with open('$RESEARCH_LOG') as f:
        content = f.read()
    topics = re.findall(r'## .* — (.*)', content)
    if topics:
        print('SON ARASTIRMALAR:')
        for t in topics[-5:]:
            print(f'- {t}')
    else:
        print('Arastirma kaydi yok')
except:
    print('Research log yok')
" 2>/dev/null)

# New knowledge files
NEW_KNOWLEDGE=$(python3 -c "
import os, glob
from datetime import datetime, timedelta
cutoff = datetime.now() - timedelta(days=7)
files = glob.glob('$KNOWLEDGE_DIR/*.md')
recent = []
for f in files:
    mtime = datetime.fromtimestamp(os.path.getmtime(f))
    if mtime >= cutoff:
        recent.append(os.path.basename(f))
if recent:
    print('YENI BILGI DOSYALARI (son 7 gun):')
    for r in recent:
        print(f'- {r}')
else:
    print('Son 7 gunde yeni bilgi dosyasi yok')
" 2>/dev/null)

log "Sinyaller toplandi"
echo "$TRAJECTORY_LESSONS"
echo "$COST_PATTERNS"
echo "$RESEARCH_TOPICS"
echo "$NEW_KNOWLEDGE"

# === STEP 2: ANALYZE CURRENT PROMPT ===
step "2/5 MEVCUT PROMPT ANALIZI"

CURRENT_LINES=$(wc -l < "$IDENTITY_PROMPT" | tr -d ' ')
CURRENT_SIZE=$(wc -c < "$IDENTITY_PROMPT" | tr -d ' ')
log "Mevcut prompt: $CURRENT_LINES satir, $CURRENT_SIZE byte"

# === STEP 3: GENERATE EVOLUTION SUGGESTIONS ===
step "3/5 EVRIM ONERILERI"

SUGGESTIONS=$(python3 << 'PYEOF'
import json, os

trajectory_lessons = []
try:
    with open(os.path.expanduser("~/.agent-evolution/memory/trajectory-pool.json")) as f:
        pool = json.load(f)
    for e in pool.get("entries", []):
        trajectory_lessons.extend(e.get("lessons", []))
except:
    pass

suggestions = []

# Rule 1: If there are trajectory lessons not in prompt, suggest adding
with open(os.path.expanduser("~/.agent-evolution/scripts/identity-prompt.txt")) as f:
    current = f.read()

for lesson in trajectory_lessons:
    # Check if key phrases from lesson are in prompt
    key_words = [w for w in lesson.lower().split() if len(w) > 5]
    found = sum(1 for w in key_words if w in current.lower())
    if found < len(key_words) * 0.3:  # less than 30% overlap
        suggestions.append(f"YENI KURAL: \"{lesson}\"")

# Rule 2: If cost is high for certain models, suggest optimization
try:
    from collections import defaultdict
    costs = defaultdict(lambda: {"calls": 0, "cost": 0})
    with open(os.path.expanduser("~/.agent-evolution/memory/cost-log.jsonl")) as f:
        for line in f:
            e = json.loads(line.strip())
            m = e.get("model", "?")
            costs[m]["calls"] += 1
            costs[m]["cost"] += float(e.get("cost", 0))
    for m, s in costs.items():
        if s["cost"] > 5:
            suggestions.append(f"MALIYET UYARISI: {m} modeli toplam ${s['cost']:.2f} yakti — Haiku'ya gecisi degerlendir")
except:
    pass

# Rule 3: Check if new tools were created but not in prompt
try:
    with open(os.path.expanduser("~/.agent-evolution/tools/catalog.json")) as f:
        catalog = json.load(f)
    tools = catalog.get("tools", [])
    for tool in tools:
        if tool["name"] not in current:
            suggestions.append(f"EKSIK ARAC: {tool['name']} prompt'ta yok — ARACLAR bolumune ekle")
except:
    pass

if not suggestions:
    print("Evrim onerisi yok — prompt guncel.")
else:
    print(f"{len(suggestions)} oneri bulundu:")
    for i, s in enumerate(suggestions, 1):
        print(f"  {i}. {s}")
PYEOF
)

echo "$SUGGESTIONS"

# === STEP 4: APPLY (if --apply) ===
if [[ "$MODE" == "apply" ]]; then
    step "4/5 UYGULAMA"

    # Backup current prompt
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-identity-prompt.txt"
    cp "$IDENTITY_PROMPT" "$BACKUP_FILE"
    log "Backup: $BACKUP_FILE"

    # Apply trajectory lessons to prompt
    python3 << 'APPLY_PYEOF'
import json, os
from datetime import datetime

prompt_path = os.path.expanduser("~/.agent-evolution/scripts/identity-prompt.txt")
with open(prompt_path) as f:
    content = f.read()

# Collect new lessons
new_rules = []
try:
    with open(os.path.expanduser("~/.agent-evolution/memory/trajectory-pool.json")) as f:
        pool = json.load(f)
    for e in pool.get("entries", []):
        for lesson in e.get("lessons", []):
            key_words = [w for w in lesson.lower().split() if len(w) > 5]
            found = sum(1 for w in key_words if w in content.lower())
            if found < len(key_words) * 0.3:
                new_rules.append(lesson)
except:
    pass

if new_rules:
    # Append to KURAL section
    rules_text = "\n".join(f"- {r}" for r in new_rules[:5])  # max 5 new rules
    evolution_note = f"\n\n# Evolved: {datetime.now().strftime('%Y-%m-%d')} — {len(new_rules)} yeni kural trajectory'den eklendi\n{rules_text}"

    with open(prompt_path, "a") as f:
        f.write(evolution_note)

    print(f"{len(new_rules)} kural eklendi")
else:
    print("Eklenecek yeni kural yok")
APPLY_PYEOF

    # Log evolution
    cat >> "$EVOLUTION_LOG" << EOF

## Prompt Evolution — $(date +%Y-%m-%d)
- **Tetikleyici:** evolve-prompt.sh --apply
- **Version:** $NEXT_VER
- **Corrections (24h):** $CORRECTION_COUNT
- **Sinyaller:** trajectory lessons, cost patterns, research topics, correction events
- **Backup:** $BACKUP_FILE
- **Sonuc:** Prompt guncellendi
EOF

    log "Prompt evolution tamamlandi (version $NEXT_VER)"

elif [[ "$MODE" == "dry-run" ]]; then
    log "Dry-run modu — degisiklik yapilmadi"
elif [[ "$MODE" == "rollback" ]]; then
    step "ROLLBACK"
    TARGET_VER="${2:-}"
    if [[ -z "$TARGET_VER" ]]; then
        echo "Kullanim: evolve-prompt.sh --rollback v001"
        echo "Mevcut versiyonlar:"
        ls "$VERSION_DIR"/*.json 2>/dev/null | sort -r | head -5
        exit 1
    fi
    VER_FILE="$VERSION_DIR/${TARGET_VER}.json"
    if [[ ! -f "$VER_FILE" ]]; then
        echo "Versiyon bulunamadi: $VER_FILE"
        exit 1
    fi
    log "Rollback: $TARGET_VER → AGENTS.md geri yuklenecek"
    python3 << ROLLEOF
import json, re, os

with open("$VER_FILE") as f:
    ver = json.load(f)

with open(os.path.expanduser("~/.agent-evolution/AGENTS.md")) as f:
    agents = f.read()

for section_name, content in ver.get("sections", {}).items():
    pattern = rf"(## {re.escape(section_name)}.*?\n).*?(?=\n## |\Z)"
    replacement = rf"\g<1>{content}\n"
    agents = re.sub(pattern, replacement, agents, flags=re.DOTALL)

with open(os.path.expanduser("~/.agent-evolution/AGENTS.md"), "w") as f:
    f.write(agents)
print(f"AGENTS.md rollback to {ver['version']} tamamlandi")
ROLLEOF

    cat >> "$EVOLUTION_LOG" << EOF

## Prompt ROLLBACK — $(date +%Y-%m-%d)
- **Hedef:** $TARGET_VER
- **Sonuc:** AGENTS.md geri yuklendi
EOF

else
    log "Analiz tamamlandi. Uygulamak icin: evolve-prompt.sh --apply"
fi
