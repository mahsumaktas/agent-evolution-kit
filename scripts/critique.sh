#!/usr/bin/env bash
# critique.sh — Cross-Agent Critique (MAR Pattern)
# Multi-agent review: bir agent, diger agent'in ciktisini degerlendirir.
#
# Kaynak: MAR (arxiv 2512.20845), docs/cross-agent-critique.md
#
# Kullanim:
#   critique.sh --output <file> --agent <producer>
#   critique.sh --matrix
#   critique.sh --batch
set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
BRIDGE="$AEK_HOME/scripts/bridge.sh"
CRITIQUE_DIR="$AEK_HOME/memory/critiques"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
TODAY=$(date +%Y-%m-%d)
MAX_DAILY_CRITIQUES=5
MAX_CONTENT_CHARS=2000
MAX_BATCH_ITEMS=3

# --- Renkler ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[critique]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[critique]${NC} $1" >&2; }
err() { echo -e "${RED}[critique]${NC} $1" >&2; }

mkdir -p "$CRITIQUE_DIR"

# --- Critique Matrisi ---
# Format: PRODUCER:CRITIC:AREA
CRITIQUE_MATRIX=(
    "scout:analyst:Research depth, source diversity"
    "social-agent:writer:Tone, engagement, accuracy"
    "finance-agent:guardian:Risk assessment, assumptions"
    "writer:social-agent:Social media fit"
    "analyst:scout:Completeness, missing areas"
    "analytics-agent:guardian:Measurement accuracy"
)
DEFAULT_CRITIC="oracle"
DEFAULT_AREA="General quality review"

# --- Yardimci Fonksiyonlar ---

# Bugunun critique sayisini say
count_today_critiques() {
    find "$CRITIQUE_DIR" -maxdepth 1 -name "${TODAY}-*.md" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Gunluk limit kontrolu
check_daily_limit() {
    local count
    count=$(count_today_critiques)
    if [[ "$count" -ge "$MAX_DAILY_CRITIQUES" ]]; then
        err "Gunluk critique limiti asildi ($count/$MAX_DAILY_CRITIQUES). Yarin tekrar deneyin."
        exit 1
    fi
    local remaining=$((MAX_DAILY_CRITIQUES - count))
    log "Gunluk critique: $count/$MAX_DAILY_CRITIQUES (kalan: $remaining)"
    echo "$remaining"
}

# Matris'ten critic ve area bul
lookup_critic() {
    local producer="$1"
    local producer_lower
    producer_lower=$(echo "$producer" | tr '[:upper:]' '[:lower:]')
    for entry in "${CRITIQUE_MATRIX[@]}"; do
        local p c a
        p=$(echo "$entry" | cut -d: -f1)
        c=$(echo "$entry" | cut -d: -f2)
        a=$(echo "$entry" | cut -d: -f3-)
        if [[ "$p" == "$producer_lower" ]]; then
            echo "${c}:${a}"
            return 0
        fi
    done
    # Fallback
    echo "${DEFAULT_CRITIC}:${DEFAULT_AREA}"
    return 0
}

# Bridge varligini kontrol et
check_bridge() {
    if [[ ! -x "$BRIDGE" ]]; then
        err "bridge.sh bulunamadi: $BRIDGE"
        exit 127
    fi
}

# Verdict cikart (APPROVE / SUGGEST / FLAG)
parse_verdict() {
    local critique_text="$1"
    if echo "$critique_text" | grep -qi "Verdict.*APPROVE"; then
        echo "APPROVE"
    elif echo "$critique_text" | grep -qi "Verdict.*FLAG"; then
        echo "FLAG"
    elif echo "$critique_text" | grep -qi "Verdict.*SUGGEST"; then
        echo "SUGGEST"
    else
        echo "UNKNOWN"
    fi
}

# --- Kullanim ---
usage() {
    cat >&2 <<'EOF'
Oracle Cross-Agent Critique — MAR Pattern

Kullanim:
  critique.sh --output <file> --agent <producer>   Ciktiyi degerlendir
  critique.sh --matrix                              Matrisi goster
  critique.sh --batch                               Son yuksek etkili gorevleri degerlendir

Secenekler:
  --output <file>    Degerlendirilecek dosya yolu
  --agent <name>     Ureticinin agent adi (scout, social-agent, finance-agent, writer, analyst, analytics-agent)
  --matrix           Critique eslestirme matrisini goster
  --batch            Trajectory pool'dan son 7 gunun yuksek etkili gorevlerini degerlendir
  --help, -h         Bu yardim mesajini goster

Ornek:
  critique.sh --output ~/.agent-evolution/memory/reflections/scout/2026-03-01-scout.md --agent scout
  critique.sh --batch
EOF
    exit 1
}

# --- --matrix komutu ---
cmd_matrix() {
    echo ""
    echo -e "${BOLD}  Cross-Agent Critique Matrisi (MAR Pattern)${NC}"
    echo -e "  ${CYAN}============================================${NC}"
    echo ""
    printf "  ${BOLD}%-12s  %-10s  %s${NC}\n" "Uretici" "Elestirmen" "Kontrol Alani"
    printf "  %-12s  %-10s  %s\n" "--------" "----------" "-------------"
    for entry in "${CRITIQUE_MATRIX[@]}"; do
        local p c a
        p=$(echo "$entry" | cut -d: -f1)
        c=$(echo "$entry" | cut -d: -f2)
        a=$(echo "$entry" | cut -d: -f3-)
        printf "  %-12s  %-10s  %s\n" "$p" "$c" "$a"
    done
    printf "  %-12s  %-10s  %s\n" "* (diger)" "$DEFAULT_CRITIC" "$DEFAULT_AREA"
    echo ""
    echo -e "  ${YELLOW}Gunluk limit: $MAX_DAILY_CRITIQUES | Bugun: $(count_today_critiques)${NC}"
    echo ""
}

# --- --output --agent komutu ---
cmd_critique() {
    local output_file="$1"
    local producer="$2"

    # Dosya kontrolu
    if [[ ! -f "$output_file" ]]; then
        err "Dosya bulunamadi: $output_file"
        exit 1
    fi

    check_bridge

    # Gunluk limit
    local remaining
    remaining=$(check_daily_limit)
    if [[ "$remaining" -le 0 ]]; then
        exit 1
    fi

    # Critic ve area bul
    local lookup_result critic area
    lookup_result=$(lookup_critic "$producer")
    critic=$(echo "$lookup_result" | cut -d: -f1)
    area=$(echo "$lookup_result" | cut -d: -f2-)

    log "Uretici: $producer | Elestirmen: $critic | Alan: $area"

    # Icerik oku (max 2000 karakter)
    local content
    content=$(head -c "$MAX_CONTENT_CHARS" "$output_file")

    if [[ -z "$content" ]]; then
        err "Dosya bos: $output_file"
        exit 1
    fi

    # Critique prompt olustur
    local prompt
    prompt="You are acting as ${critic} agent, reviewing ${producer}'s output.
Focus area: ${area}

OUTPUT TO REVIEW:
---
${content}
---

Provide a concise critique (max 100 words) in this format:
## Verdict: APPROVE / SUGGEST / FLAG
## Strong points (1-2)
- ...
## Issues (if any, 1-3)
- ...
## Recommendation (if any)
- ..."

    # Bridge cagir (--quick --text --silent)
    log "Bridge cagriliyor (haiku, quick mode)..."
    local result
    result=$(ORACLE_CALLER="critique-${critic}" "$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null) || {
        local exit_code=$?
        err "Bridge cagrisi basarisiz (exit: $exit_code)"
        exit "$exit_code"
    }

    if [[ -z "$result" ]]; then
        err "Bridge bos cikti dondu"
        exit 1
    fi

    # Dosyaya kaydet
    local critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}.md"
    {
        echo "# Critique: ${TODAY} - ${critic} reviews ${producer}"
        echo ""
        echo "**Dosya:** $(basename "$output_file")"
        echo "**Elestirmen:** ${critic} | **Alan:** ${area}"
        echo ""
        echo "$result"
    } > "$critique_file"

    log "Critique kaydedildi: $critique_file"

    # Verdict cikart
    local verdict
    verdict=$(parse_verdict "$result")

    # Ozet goster
    echo ""
    echo -e "${BOLD}  Critique Sonucu${NC}"
    echo -e "  ${CYAN}=================${NC}"
    echo -e "  Uretici:    ${producer}"
    echo -e "  Elestirmen: ${critic}"
    echo -e "  Alan:       ${area}"
    case "$verdict" in
        APPROVE) echo -e "  Verdict:    ${GREEN}${verdict}${NC}" ;;
        SUGGEST) echo -e "  Verdict:    ${YELLOW}${verdict}${NC}" ;;
        FLAG)    echo -e "  Verdict:    ${RED}${verdict}${NC}" ;;
        *)       echo -e "  Verdict:    ${verdict}" ;;
    esac
    echo -e "  Dosya:      ${critique_file}"
    echo ""

    # Critique icerigini goster
    echo "$result"
}

# --- --batch komutu ---
cmd_batch() {
    check_bridge

    # Gunluk limit
    local remaining
    remaining=$(check_daily_limit)
    if [[ "$remaining" -le 0 ]]; then
        exit 1
    fi

    # Trajectory pool kontrolu
    if [[ ! -f "$TRAJECTORY" ]]; then
        err "Trajectory pool bulunamadi: $TRAJECTORY"
        exit 1
    fi

    log "Trajectory pool'dan son 7 gunun yuksek etkili gorevleri arastiriliyor..."

    # Python ile trajectory parse et — son 7 gun, yuksek cost/duration, bilinen producer
    local batch_items
    batch_items=$(python3 - "$TRAJECTORY" "$MAX_BATCH_ITEMS" <<'PYEOF'
import json, sys, os
from datetime import datetime, timedelta

trajectory_file = sys.argv[1]
max_items = int(sys.argv[2])

# Matristeki bilinen producer'lar
known_producers = {"scout", "analyst", "social-agent", "writer", "finance-agent", "guardian", "analytics-agent"}

try:
    with open(trajectory_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)

entries = data.get("entries", []) if isinstance(data, dict) else data
if not entries:
    sys.exit(0)

cutoff = datetime.now() - timedelta(days=7)
candidates = []

for e in entries:
    ts = e.get("timestamp", "")
    try:
        if "T" in ts:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00").replace("+00:00", ""))
        else:
            continue
    except (ValueError, TypeError):
        continue

    # Sadece son 7 gun
    if dt.replace(tzinfo=None) < cutoff:
        continue

    # Agent/caller bilgisi
    agent = e.get("agent", e.get("caller", "")).lower()
    # Agent adinda bilinen producer var mi?
    matched_producer = None
    for p in known_producers:
        if p in agent:
            matched_producer = p
            break

    if not matched_producer:
        continue

    # Yuksek etki skoru: cost + duration bazli
    cost = float(e.get("cost_usd", e.get("cost", 0)) or 0)
    duration = int(e.get("duration_s", 0) or 0)
    tokens = int(e.get("tokens_used", 0) or 0)
    impact = cost * 100 + duration / 60 + tokens / 1000

    task = e.get("task", "")[:200]
    if not task:
        continue

    candidates.append({
        "producer": matched_producer,
        "task": task,
        "impact": impact,
        "id": e.get("id", "unknown")
    })

# En yuksek impact'e gore sirala
candidates.sort(key=lambda x: x["impact"], reverse=True)

# Ilk N tanesini al
for item in candidates[:max_items]:
    # TAB-separated: producer\ttask\tid
    print(f"{item['producer']}\t{item['task']}\t{item['id']}")
PYEOF
    ) || true

    if [[ -z "$batch_items" ]]; then
        log "Son 7 gunde yuksek etkili, bilinen producer'a ait gorev bulunamadi."
        exit 0
    fi

    local count=0
    while IFS=$'\t' read -r producer task traj_id; do
        # Gunluk limit tekrar kontrol
        local current_count
        current_count=$(count_today_critiques)
        if [[ "$current_count" -ge "$MAX_DAILY_CRITIQUES" ]]; then
            warn "Gunluk limit asildi, kalan batch atlanacak."
            break
        fi

        count=$((count + 1))
        log "Batch [$count]: $producer gorevi degerlendirilecek (traj: $traj_id)"

        # Critic ve area bul
        local lookup_result critic area
        lookup_result=$(lookup_critic "$producer")
        critic=$(echo "$lookup_result" | cut -d: -f1)
        area=$(echo "$lookup_result" | cut -d: -f2-)

        # Prompt — dosya yerine trajectory task icerigini kullan
        local prompt
        prompt="You are acting as ${critic} agent, reviewing ${producer}'s output.
Focus area: ${area}

TASK OUTPUT TO REVIEW (from trajectory ${traj_id}):
---
${task}
---

Provide a concise critique (max 100 words) in this format:
## Verdict: APPROVE / SUGGEST / FLAG
## Strong points (1-2)
- ...
## Issues (if any, 1-3)
- ...
## Recommendation (if any)
- ..."

        local result
        result=$(ORACLE_CALLER="critique-batch-${critic}" "$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null) || {
            warn "Batch critique basarisiz: $producer ($traj_id), atlaniyor."
            continue
        }

        if [[ -z "$result" ]]; then
            warn "Batch critique bos cikti: $producer ($traj_id), atlaniyor."
            continue
        fi

        # Kaydet
        local critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}-batch.md"
        # Ayni dosya varsa suffix ekle
        if [[ -f "$critique_file" ]]; then
            critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}-batch-${count}.md"
        fi
        {
            echo "# Batch Critique: ${TODAY} - ${critic} reviews ${producer}"
            echo ""
            echo "**Trajectory:** ${traj_id}"
            echo "**Elestirmen:** ${critic} | **Alan:** ${area}"
            echo ""
            echo "$result"
        } > "$critique_file"

        local verdict
        verdict=$(parse_verdict "$result")

        case "$verdict" in
            APPROVE) echo -e "  ${GREEN}[${verdict}]${NC} ${producer} (${traj_id}) -> ${critic}" ;;
            SUGGEST) echo -e "  ${YELLOW}[${verdict}]${NC} ${producer} (${traj_id}) -> ${critic}" ;;
            FLAG)    echo -e "  ${RED}[${verdict}]${NC} ${producer} (${traj_id}) -> ${critic}" ;;
            *)       echo -e "  [${verdict}] ${producer} (${traj_id}) -> ${critic}" ;;
        esac

    done <<< "$batch_items"

    echo ""
    log "Batch tamamlandi: $count gorev degerlendirildi."
}

# --- ARG PARSE ---
MODE=""
OUTPUT_FILE=""
AGENT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --matrix)   MODE="matrix"; shift ;;
        --batch)    MODE="batch"; shift ;;
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        --agent)    AGENT_NAME="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          err "Bilinmeyen secenek: $1"; usage ;;
    esac
done

# Mode belirleme
if [[ "$MODE" == "matrix" ]]; then
    cmd_matrix
    exit 0
fi

if [[ "$MODE" == "batch" ]]; then
    cmd_batch
    exit 0
fi

if [[ -n "$OUTPUT_FILE" && -n "$AGENT_NAME" ]]; then
    cmd_critique "$OUTPUT_FILE" "$AGENT_NAME"
    exit 0
fi

# Hicbir mod secilmediyse
if [[ -n "$OUTPUT_FILE" && -z "$AGENT_NAME" ]]; then
    err "--agent parametresi gerekli"
    exit 1
fi

if [[ -z "$OUTPUT_FILE" && -n "$AGENT_NAME" ]]; then
    err "--output parametresi gerekli"
    exit 1
fi

err "Bir komut secmelisiniz: --matrix, --batch, veya --output <file> --agent <name>"
usage
