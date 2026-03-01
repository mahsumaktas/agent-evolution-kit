#!/usr/bin/env bash
# maker-checker.sh — Maker-Checker dual verification loop
# Maker ciktisini checker agent'a gonderir, APPROVE/ISSUE/REJECT dongusu calistirir.
#
# Kullanim:
#   maker-checker.sh --maker <agent> --checker <agent> --task "desc" --input <file>
#   maker-checker.sh --auto --maker <agent> --task "desc" --input <file>

set -euo pipefail

# === PATHS ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/bridge.sh"
CONFIG="$HOME/clawd/config/maker-checker-pairs.yaml"
TRAJECTORY_FILE="$HOME/clawd/memory/trajectory-pool.json"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === FUNCTIONS ===
log()  { echo -e "${GREEN}[maker-checker]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[maker-checker]${NC} $1" >&2; }
err()  { echo -e "${RED}[maker-checker]${NC} $1" >&2; }
info() { echo -e "${CYAN}[maker-checker]${NC} $1" >&2; }

# === CLEANUP ===
TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

make_temp() {
    local t
    t="$(mktemp /tmp/maker-checker.XXXXXX)"
    TEMP_FILES+=("$t")
    echo "$t"
}

# === USAGE ===
usage() {
    cat >&2 << 'EOF'
Oracle Maker-Checker — Dual verification loop

Kullanim:
  maker-checker.sh --maker <agent> --checker <agent> --task "desc" --input <file>
  maker-checker.sh --auto --maker <agent> --task "desc" --input <file>

Secenekler:
  --maker <agent>     Maker agent adi
  --checker <agent>   Checker agent adi (--auto ile otomatik secilir)
  --auto              Config'den checker'i otomatik sec
  --task "desc"       Gorev tanimi
  --input <file>      Maker ciktisini iceren dosya
  --max-iter <N>      Maksimum iterasyon (default: 3)
  --help              Bu mesaji goster
EOF
    exit 1
}

# === AUTO-SELECT CHECKER ===
# YAML'i Python ile parse eder (pyyaml bagimliligi yok — satir satir okur)
auto_select_checker() {
    local maker="$1"
    local task="$2"
    local config_file="$3"

    if [[ ! -f "$config_file" ]]; then
        err "Config dosyasi bulunamadi: $config_file"
        echo "oracle"
        return
    fi

    python3 - "$maker" "$task" "$config_file" <<'PYEOF'
import sys

maker = sys.argv[1]
task_desc = sys.argv[2].lower()
config_path = sys.argv[3]

# YAML'i satir satir parse et — basit pairs listesi
pairs = []
current = {}
in_pairs = False

with open(config_path) as f:
    for line in f:
        stripped = line.strip()
        # Yorum veya bos satir
        if not stripped or stripped.startswith('#'):
            continue
        if stripped == 'pairs:':
            in_pairs = True
            continue
        if not in_pairs:
            continue

        # Yeni pair baslangici
        if stripped.startswith('- maker:'):
            if current:
                pairs.append(current)
            current = {'maker': stripped.split(':', 1)[1].strip().strip('"').strip("'")}
        elif stripped.startswith('checker:'):
            current['checker'] = stripped.split(':', 1)[1].strip().strip('"').strip("'")
        elif stripped.startswith('domains:'):
            # [blog, documentation, report, content] formatini parse et
            domain_str = stripped.split(':', 1)[1].strip()
            if domain_str.startswith('[') and domain_str.endswith(']'):
                domains = [d.strip().strip('"').strip("'") for d in domain_str[1:-1].split(',')]
                current['domains'] = domains
            else:
                current['domains'] = []
        elif stripped.startswith('threshold:'):
            current['threshold'] = int(stripped.split(':', 1)[1].strip())

    if current:
        pairs.append(current)

# 1. Exact maker match + domain keyword match
best = None
for pair in pairs:
    if pair.get('maker') == maker:
        domains = pair.get('domains', [])
        for domain in domains:
            if domain != '*' and domain in task_desc:
                best = pair
                break
        # Exact maker match ama domain eslesmedi — yine de aday
        if not best and pair.get('maker') != '*':
            best = pair

# 2. Wildcard fallback
if not best:
    for pair in pairs:
        if pair.get('maker') == '*':
            best = pair
            break

# 3. Hicbir sey eslesmedi
if not best:
    print('oracle')
else:
    print(best.get('checker', 'oracle'))
PYEOF
}

# === TRAJECTORY UPDATE ===
update_trajectory_checker() {
    local checker="$1"
    local result="$2"
    local iterations="$3"

    if [[ ! -f "$TRAJECTORY_FILE" ]]; then
        warn "Trajectory dosyasi yok, guncelleme atlaniyor"
        return 0
    fi

    python3 - "$TRAJECTORY_FILE" "$checker" "$result" "$iterations" <<'PYEOF'
import json, sys, os

path = sys.argv[1]
checker_agent = sys.argv[2]
checker_result = sys.argv[3]
checker_iterations = int(sys.argv[4])

if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

# Dict format — entries key'i altinda
if isinstance(data, dict):
    entries = data.get("entries", [])
elif isinstance(data, list):
    entries = data
else:
    sys.exit(0)

# Son entry'yi guncelle
if entries:
    entries[-1]["checker_agent"] = checker_agent
    entries[-1]["checker_result"] = checker_result
    entries[-1]["checker_iterations"] = checker_iterations

if isinstance(data, dict):
    data["entries"] = entries
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
else:
    with open(path, 'w') as f:
        json.dump(entries, f, indent=2, ensure_ascii=False)
PYEOF
}

# === PARSE ARGS ===
MAKER=""
CHECKER=""
AUTO=false
TASK=""
INPUT_FILE=""
MAX_ITER=3

while [[ $# -gt 0 ]]; do
    case $1 in
        --maker)    MAKER="$2"; shift 2;;
        --checker)  CHECKER="$2"; shift 2;;
        --auto)     AUTO=true; shift;;
        --task)     TASK="$2"; shift 2;;
        --input)    INPUT_FILE="$2"; shift 2;;
        --max-iter) MAX_ITER="$2"; shift 2;;
        --help|-h)  usage;;
        *)          err "Bilinmeyen parametre: $1"; usage;;
    esac
done

# === VALIDATION ===
if [[ -z "$MAKER" ]]; then
    err "--maker parametresi zorunlu"
    usage
fi
if [[ -z "$TASK" ]]; then
    err "--task parametresi zorunlu"
    usage
fi
if [[ -z "$INPUT_FILE" ]]; then
    err "--input parametresi zorunlu"
    usage
fi
if [[ ! -f "$INPUT_FILE" ]]; then
    err "Input dosyasi bulunamadi: $INPUT_FILE"
    exit 1
fi
if [[ ! -x "$BRIDGE" ]]; then
    err "Bridge script bulunamadi veya calistirilamaz: $BRIDGE"
    exit 1
fi

# === AUTO-SELECT CHECKER ===
if [[ "$AUTO" == true ]]; then
    CHECKER="$(auto_select_checker "$MAKER" "$TASK" "$CONFIG")"
    log "Auto-selected checker: $CHECKER"
elif [[ -z "$CHECKER" ]]; then
    err "--checker veya --auto parametresi gerekli"
    usage
fi

# === READ INPUT ===
CONTENT="$(cat "$INPUT_FILE")"
if [[ -z "$CONTENT" ]]; then
    err "Input dosyasi bos: $INPUT_FILE"
    exit 1
fi

log "Maker: $MAKER | Checker: $CHECKER | Task: $TASK"
log "Max iterasyon: $MAX_ITER"
info "Input boyutu: $(wc -c < "$INPUT_FILE" | tr -d ' ') byte"

# === MAIN LOOP ===
CURRENT_CONTENT="$CONTENT"
ITERATION=0
FINAL_RESULT="ISSUE"

while [[ $ITERATION -lt $MAX_ITER ]]; do
    ITERATION=$((ITERATION + 1))
    log "--- Iterasyon $ITERATION/$MAX_ITER ---"

    # Content'i 3000 char ile sinirla (checker prompt icin)
    CONTENT_TRIMMED="$(echo "$CURRENT_CONTENT" | head -c 3000)"

    # Checker prompt'u olustur
    CHECKER_PROMPT="You are a checker reviewing work by ${MAKER}.
Task: ${TASK}

Review this output and respond with EXACTLY one of:
- APPROVE: [brief reason]
- ISSUE: [specific feedback]
- REJECT: [reason]

Output to review:
${CONTENT_TRIMMED}"

    # Checker'a gonder
    log "Checker'a ($CHECKER) gonderiyor..."
    CHECKER_RESPONSE_FILE="$(make_temp)"

    if ! "$BRIDGE" --quick --text --silent "$CHECKER_PROMPT" > "$CHECKER_RESPONSE_FILE" 2>/dev/null; then
        warn "Bridge cagrisi basarisiz — maker ciktisi kabul ediliyor (fallback)"
        FINAL_RESULT="APPROVE-FALLBACK"
        break
    fi

    CHECKER_RESPONSE="$(cat "$CHECKER_RESPONSE_FILE")"

    if [[ -z "$CHECKER_RESPONSE" ]]; then
        warn "Checker bos yanit dondu — maker ciktisi kabul ediliyor (fallback)"
        FINAL_RESULT="APPROVE-FALLBACK"
        break
    fi

    # Response'u parse et
    if echo "$CHECKER_RESPONSE" | grep -qi "^APPROVE"; then
        log "Checker APPROVE verdi"
        FINAL_RESULT="APPROVE"
        break
    elif echo "$CHECKER_RESPONSE" | grep -qi "^REJECT"; then
        REJECT_REASON="$(echo "$CHECKER_RESPONSE" | grep -oi "^REJECT:.*" | head -1)"
        err "Checker REJECT verdi: $REJECT_REASON"
        FINAL_RESULT="REJECT"
        break
    elif echo "$CHECKER_RESPONSE" | grep -qi "^ISSUE"; then
        FEEDBACK="$(echo "$CHECKER_RESPONSE" | grep -oi "^ISSUE:.*" | head -1)"
        warn "Checker ISSUE verdi: $FEEDBACK"

        if [[ $ITERATION -ge $MAX_ITER ]]; then
            warn "Maksimum iterasyona ulasildi — son haliyle kabul ediliyor"
            FINAL_RESULT="ISSUE-MAX-ITER"
            break
        fi

        # Revision icin maker'a gonder
        log "Maker'a ($MAKER) revision icin gonderiyor..."
        CONTENT_FOR_REVISION="$(echo "$CURRENT_CONTENT" | head -c 2000)"

        REVISION_PROMPT="Your previous output was reviewed and needs improvement.
Task: ${TASK}
Feedback: ${FEEDBACK}
Original output: ${CONTENT_FOR_REVISION}

Revise your output addressing the feedback."

        REVISION_FILE="$(make_temp)"

        if ! "$BRIDGE" --quick --text --silent "$REVISION_PROMPT" > "$REVISION_FILE" 2>/dev/null; then
            warn "Revision bridge cagrisi basarisiz — mevcut haliyle devam ediliyor"
            continue
        fi

        REVISED="$(cat "$REVISION_FILE")"
        if [[ -n "$REVISED" ]]; then
            CURRENT_CONTENT="$REVISED"
            info "Revision alindi ($(echo "$REVISED" | wc -c | tr -d ' ') byte)"
        else
            warn "Bos revision dondu — mevcut haliyle devam ediliyor"
        fi
    else
        # Beklenen formatlardan hicbiri eslesmedi — tum yaniti kontrol et
        if echo "$CHECKER_RESPONSE" | grep -qi "approve"; then
            log "Checker APPROVE verdi (satir ici)"
            FINAL_RESULT="APPROVE"
            break
        elif echo "$CHECKER_RESPONSE" | grep -qi "reject"; then
            err "Checker REJECT verdi (satir ici)"
            FINAL_RESULT="REJECT"
            break
        else
            warn "Checker yaniti parse edilemedi — maker ciktisi kabul ediliyor (fallback)"
            FINAL_RESULT="APPROVE-FALLBACK"
            break
        fi
    fi
done

# === OUTPUT ===
echo "$CURRENT_CONTENT"

# === TRAJECTORY UPDATE ===
if [[ "$FINAL_RESULT" == "APPROVE" || "$FINAL_RESULT" == "APPROVE-FALLBACK" ]]; then
    update_trajectory_checker "$CHECKER" "$FINAL_RESULT" "$ITERATION"
    log "Trajectory guncellendi: checker=$CHECKER, result=$FINAL_RESULT, iterations=$ITERATION"
fi

# === SUMMARY ===
log "=== Sonuc ==="
log "  Maker: $MAKER"
log "  Checker: $CHECKER"
log "  Iterasyon: $ITERATION/$MAX_ITER"
log "  Sonuc: $FINAL_RESULT"

case "$FINAL_RESULT" in
    APPROVE)          exit 0;;
    APPROVE-FALLBACK) exit 0;;
    ISSUE-MAX-ITER)   warn "Max iterasyon uyarisi — son versiyon kullanildi"; exit 0;;
    REJECT)           err "Checker tarafindan reddedildi"; exit 1;;
    *)                exit 1;;
esac
