#!/usr/bin/env bash
# iterative-research.sh — ComoRAG-inspired Iterative Reasoning for Oracle
#
# Kaynak: https://github.com/EternityJune25/ComoRAG (arXiv:2508.10419)
# Mimik: Reason → Probe → Retrieve → Consolidate → Resolve
#
# Kullanım:
#   iterative-research.sh "Karmaşık soru burada"
#   iterative-research.sh --question "Soru" --max-cycles 5 --lang tr
#   iterative-research.sh --question "Soru" --debug

set -euo pipefail

# === CONFIG ===
BRIDGE="${HOME}/.agent-evolution/scripts/bridge.sh"
MAX_CYCLES=5
LANG="tr"
DEBUG=false
QUESTION=""

# === COLORS ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${CYAN}[iter-research]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[iter-research]${NC} $1" >&2; }
err()   { echo -e "${RED}[iter-research]${NC} $1" >&2; }
debug() { [[ "$DEBUG" == "true" ]] && echo -e "${YELLOW}[DEBUG]${NC} $1" >&2 || true; }
step()  { echo -e "${BOLD}${GREEN}[CYCLE $1/${MAX_CYCLES}]${NC} $2" >&2; }

# === ARGS ===
while [[ $# -gt 0 ]]; do
    case $1 in
        --question|-q) QUESTION="$2"; shift 2;;
        --max-cycles)  MAX_CYCLES="$2"; shift 2;;
        --lang)        LANG="$2"; shift 2;;
        --debug)       DEBUG=true; shift;;
        --help|-h)
            echo "Kullanım: iterative-research.sh [--question \"soru\"] [--max-cycles N] [--lang tr|en] [--debug]"
            echo "Örnek: iterative-research.sh \"2025'te yapay zeka chip pazarında NVIDIA'nın pazar payı nedir ve rekabet durumu nasıl?\""
            exit 0;;
        *) QUESTION="$1"; shift;;
    esac
done

if [[ -z "$QUESTION" ]]; then
    err "Soru gerekli. Kullanım: iterative-research.sh \"sorunuz\""
    exit 1
fi

# === TEMP DIR ===
WORK_DIR=$(mktemp -d)
EVIDENCE_POOL="${WORK_DIR}/evidence_pool.json"
CYCLE_LOG="${WORK_DIR}/cycle_log.json"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Init evidence pool (3-layer mimicking ComoRAG VER/SEM/EPI)
cat > "$EVIDENCE_POOL" << 'EOF'
{
  "question": "",
  "veridical": [],
  "semantic": [],
  "episodic": [],
  "probes_used": [],
  "fusion_summaries": [],
  "cycles": []
}
EOF

# Set question in pool
python3 -c "
import json, sys
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)
pool['question'] = sys.argv[1]
with open('$EVIDENCE_POOL', 'w') as f:
    json.dump(pool, f, ensure_ascii=False, indent=2)
" "$QUESTION"

echo "[]" > "$CYCLE_LOG"

# === BRIDGE CHECK ===
if [[ ! -x "$BRIDGE" ]]; then
    warn "bridge.sh bulunamadı: $BRIDGE — claude CLI ile devam ediliyor"
    BRIDGE="claude"
fi

# === FUNCTIONS ===

# Run a prompt through Claude and get response
ask_claude() {
    local prompt="$1"
    local max_tokens="${2:-2000}"
    
    if [[ -x "${HOME}/.agent-evolution/scripts/bridge.sh" ]]; then
        echo "$prompt" | "${HOME}/.agent-evolution/scripts/bridge.sh" --stdin 2>/dev/null || \
        claude --print "$prompt" 2>/dev/null
    else
        claude --print "$prompt" 2>/dev/null
    fi
}

# Web search using brave/web_search (via claude tool call simulation)
web_retrieve() {
    local query="$1"
    local results_file="${WORK_DIR}/search_$(echo "$query" | md5sum | cut -c1-8).txt"
    
    debug "Searching: $query"
    
    # Use Claude with web search capability
    local search_prompt="Web araması yap ve sonuçları özetle. Sadece GERÇEK BİLGİ ver, uydurma.

Sorgu: ${query}

Web araması yap (web_search tool kullan) ve şunu döndür:
1. Bulunan önemli gerçekler (madde madde)
2. Kaynaklar (URL'ler)

Eğer bilgi bulamazsan 'BULUNAMADI' yaz."

    ask_claude "$search_prompt" 1500 > "$results_file" 2>/dev/null || echo "BULUNAMADI" > "$results_file"
    cat "$results_file"
}

# PHASE 1: Initial reasoning attempt
attempt_answer() {
    local cycle="$1"
    local pool_summary="$2"
    local historical="$3"
    
    local lang_instruction=""
    if [[ "$LANG" == "tr" ]]; then
        lang_instruction="Türkçe cevap ver."
    fi
    
    local prompt="Sen gelişmiş bir araştırma analistsin. ${lang_instruction}

## Soru
${QUESTION}

## Mevcut Kanıt Havuzu

### Ham Kanıtlar (Veridical)
${pool_summary}

### Tarihsel Bulgular (Önceki döngülerden)
${historical}

## Görev
Yukarıdaki kanıtlara dayanarak soruyu cevapla.

### Cevap Formatı:
**İçerik Analizi:** (2-3 cümle özet)

**İlgili Kanıtlar:**
- [madde madde ilgili bilgiler]

**Temel Bulgular:**
- [cevabı destekleyen kritik faktlar]

**### Final Answer**
[En kısa, en doğru cevap]

ÖNEMLİ: Eğer mevcut kanıtlarla kesin bir cevap VEREMIYORSAN, Final Answer kısmına tam olarak şunu yaz: IMPASSE
Uydurma, tahmin etme, IMPASSE yaz."

    ask_claude "$prompt" 2000
}

# PHASE 2: Generate probing queries when impasse detected
generate_probes() {
    local cycle="$1"
    local current_evidence="$2"
    local previous_probes="$3"
    
    local lang_instruction=""
    if [[ "$LANG" == "tr" ]]; then
        lang_instruction="Probe'ları Türkçe yaz."
    fi
    
    local prompt="Sen bir araştırma stratejisti ve sorgulama uzmanısın. ${lang_instruction}

## Ana Soru
${QUESTION}

## Mevcut Kanıt Özeti
${current_evidence}

## Daha Önce Kullanılan Probe'lar (BUNLARLA ÇAKIŞMA)
${previous_probes}

## Görev
Mevcut kanıtlar yetersiz — impasse durumu tespit edildi.
Soruyu farklı açılardan araştırmak için 3 hedefli probe (alt-sorgu) üret.

Kurallar:
- Önceki probe'larla semantic çakışma YASAK
- Her probe FARKLI bir bilgi boyutunu hedeflemeli
- Somut entity'lere odaklan (kişi, kurum, ürün, olay, tarih)
- Arama motoruna yazılacak gibi pratik sorgular

Çıktı formatı (SADECE JSON, başka hiçbir şey):
{\"probe_1\": \"...\", \"probe_2\": \"...\", \"probe_3\": \"...\"}"

    ask_claude "$prompt" 500
}

# PHASE 3: Consolidate and fuse evidence
fuse_evidence() {
    local all_evidence="$1"
    local probe_findings="$2"
    
    local prompt="Araştırma kanıtlarını birleştir ve sentezle.

## Soru
${QUESTION}

## Toplanan Ham Kanıtlar
${all_evidence}

## Probe Bulgular
${probe_findings}

## Görev
Bu kanıtları şu 3 katmana göre sentezle:

**VERİDİKAL (Ham Olgular):** Doğrulanmış, kaynaktan doğrudan alınan spesifik bilgiler

**SEMANTİK (Kavramsal Özet):** Kanıtların birbirleriyle ilişkisi, örüntüler, çelişkiler

**EPİZODİK (Kronoloji/Nedensellik):** Olayların zamansal/nedensel zinciri

Her katman için 3-5 madde yaz. Kısa, somut."

    ask_claude "$prompt" 1500
}

# === MAIN LOOP ===
log "Başlatılıyor: '${QUESTION}'"
log "Max döngü: ${MAX_CYCLES}"

CYCLE=0
IMPASSE_DETECTED=false
PREVIOUS_PROBES="(yok)"
HISTORICAL_INFO=""
FINAL_ANSWER=""
CONFIDENCE=0
EVIDENCE_TRAIL=()

# Initial retrieval — first pass
log "İlk retrieval başlıyor..."
INITIAL_EVIDENCE=$(web_retrieve "$QUESTION" 2>/dev/null || echo "Başlangıç araması başarısız")

# Add to VER layer
python3 -c "
import json
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)
pool['veridical'].append({'source': 'initial_search', 'content': '''${INITIAL_EVIDENCE//\'/}'''})
with open('$EVIDENCE_POOL', 'w') as f:
    json.dump(pool, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true

while [[ $CYCLE -lt $MAX_CYCLES ]]; do
    CYCLE=$((CYCLE + 1))
    step "$CYCLE" "Reasoning phase..."
    
    # Build current evidence summary
    EVIDENCE_SUMMARY=$(python3 -c "
import json
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)

parts = []
for item in pool.get('veridical', []):
    parts.append(f\"[{item.get('source','?')}]: {item.get('content','')[:500]}\")
for item in pool.get('fusion_summaries', []):
    parts.append(f\"[FUSION]: {item[:500]}\")

print('\n---\n'.join(parts[:10]))  # max 10 items to avoid token explosion
" 2>/dev/null || echo "$INITIAL_EVIDENCE")
    
    debug "Evidence summary length: ${#EVIDENCE_SUMMARY}"
    
    # Attempt to answer
    RESPONSE=$(attempt_answer "$CYCLE" "$EVIDENCE_SUMMARY" "$HISTORICAL_INFO" 2>/dev/null || echo "IMPASSE")
    
    debug "Response (first 200 chars): ${RESPONSE:0:200}"
    
    # Extract Final Answer
    FINAL_SECTION=$(echo "$RESPONSE" | grep -A 999 "### Final Answer" | tail -n +2 | head -5 | tr -d '\n' | xargs)
    
    if [[ -z "$FINAL_SECTION" ]]; then
        FINAL_SECTION="IMPASSE"
    fi
    
    # Check for impasse
    if echo "$FINAL_SECTION" | grep -qi "IMPASSE"; then
        IMPASSE_DETECTED=true
        warn "Cycle ${CYCLE}: Impasse tespit edildi — probing phase başlıyor"
        
        if [[ $CYCLE -ge $MAX_CYCLES ]]; then
            warn "Max döngüye ulaşıldı. En iyi mevcut cevapla devam ediliyor."
            FINAL_ANSWER="$RESPONSE"
            CONFIDENCE=30
            break
        fi
        
        # Generate probes
        log "Probe üretiliyor..."
        PROBE_JSON=$(generate_probes "$CYCLE" "$EVIDENCE_SUMMARY" "$PREVIOUS_PROBES" 2>/dev/null || echo "{}")
        
        debug "Probe JSON: $PROBE_JSON"
        
        # Parse probes
        PROBES=$(python3 -c "
import json, sys
try:
    raw = '''${PROBE_JSON//\'/}'''
    # Find JSON in response
    import re
    match = re.search(r'\{.*\}', raw, re.DOTALL)
    if match:
        data = json.loads(match.group())
        probes = [v for k, v in sorted(data.items()) if k.startswith('probe_')]
        print('\n'.join(probes[:3]))
    else:
        print('')
except Exception as e:
    print('')
" 2>/dev/null || echo "")
        
        if [[ -z "$PROBES" ]]; then
            warn "Probe üretilemedi, döngü sonlandırılıyor"
            FINAL_ANSWER="$RESPONSE"
            CONFIDENCE=40
            break
        fi
        
        # Retrieve for each probe
        PROBE_FINDINGS=""
        NEW_PROBES_LIST=""
        
        while IFS= read -r probe; do
            [[ -z "$probe" ]] && continue
            log "Probe retrieve: '${probe}'"
            
            PROBE_RESULT=$(web_retrieve "$probe" 2>/dev/null || echo "Probe araması başarısız: $probe")
            PROBE_FINDINGS+="**Probe: ${probe}**\n${PROBE_RESULT}\n\n"
            NEW_PROBES_LIST+="${probe}\n"
            
            # Add to evidence pool
            python3 -c "
import json
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)
pool['veridical'].append({'source': 'probe: ${probe//\'/}', 'content': '''${PROBE_RESULT//\'/}'''[:1000]})
pool['probes_used'].append('${probe//\'/}')
with open('$EVIDENCE_POOL', 'w') as f:
    json.dump(pool, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true
            
        done <<< "$PROBES"
        
        # Update previous probes
        PREVIOUS_PROBES+=$'\n'"$NEW_PROBES_LIST"
        
        # Consolidate & fuse
        log "Kanıtlar birleştiriliyor (mem-fusion)..."
        FUSED=$(fuse_evidence "$EVIDENCE_SUMMARY" "$PROBE_FINDINGS" 2>/dev/null || echo "Fusion başarısız")
        
        HISTORICAL_INFO="**Döngü ${CYCLE} bulguları:**\n${FUSED}"
        
        # Add fusion to pool
        python3 -c "
import json
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)
pool['fusion_summaries'].append('Cycle ${CYCLE}: ${FUSED//\'/}')
pool['cycles'].append({'cycle': ${CYCLE}, 'status': 'impasse', 'probes': list(filter(None, '''${NEW_PROBES_LIST//\'/}'''.split('\n')))})
with open('$EVIDENCE_POOL', 'w') as f:
    json.dump(pool, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true
        
        EVIDENCE_TRAIL+=("Cycle ${CYCLE}: Impasse → ${PROBES}")
        
    else
        # Answer found
        log "Cycle ${CYCLE}: Cevap bulundu!"
        FINAL_ANSWER="$RESPONSE"
        CONFIDENCE=$((100 - (CYCLE - 1) * 15))
        
        python3 -c "
import json
with open('$EVIDENCE_POOL', 'r') as f:
    pool = json.load(f)
pool['cycles'].append({'cycle': ${CYCLE}, 'status': 'resolved'})
with open('$EVIDENCE_POOL', 'w') as f:
    json.dump(pool, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true
        
        EVIDENCE_TRAIL+=("Cycle ${CYCLE}: Resolved")
        break
    fi
    
done

# === OUTPUT ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}🦉 ORACLE — İTERATİF ARAŞTIRMA SONUCU${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BOLD}❓ SORU:${NC} ${QUESTION}"
echo ""
echo -e "${BOLD}📊 METADATA:${NC}"
echo "   Kullanılan döngü: ${CYCLE}/${MAX_CYCLES}"
echo "   Güven skoru: ${CONFIDENCE}%"
echo "   Kullanılan probe'lar: $(echo "$PREVIOUS_PROBES" | grep -c "." || echo 0)"
echo ""
echo -e "${BOLD}🔍 KANIT İZİ:${NC}"
for trail_item in "${EVIDENCE_TRAIL[@]}"; do
    echo "   → $trail_item"
done
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━ CEVAP ━━━━━━━━━━━━━${NC}"
echo ""
echo "$FINAL_ANSWER"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Save result
RESULT_DIR="${HOME}/.agent-evolution/memory/iterative-research"
mkdir -p "$RESULT_DIR"
RESULT_FILE="${RESULT_DIR}/$(date +%Y%m%d-%H%M%S)-result.md"

cat > "$RESULT_FILE" << RESULT_EOF
# Iterative Research Result
**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Cycles:** ${CYCLE}/${MAX_CYCLES}
**Confidence:** ${CONFIDENCE}%

## Question
${QUESTION}

## Evidence Trail
$(printf '%s\n' "${EVIDENCE_TRAIL[@]}")

## Answer
${FINAL_ANSWER}
RESULT_EOF

log "Sonuç kaydedildi: ${RESULT_FILE}"
