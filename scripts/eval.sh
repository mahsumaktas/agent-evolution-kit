#!/usr/bin/env bash
# Oracle Eval — Hybrid heuristic + LLM evaluation for agent outputs
# Layer 1: Zero-cost Python heuristics (score 0-100)
# Layer 2: LLM evaluation via bridge.sh (only for GRAY_ZONE)
#
# Kullanim:
#   eval.sh --layer1 <file>    # Sadece heuristic
#   eval.sh --full <file>      # Layer 1 + conditional Layer 2
#   eval.sh --score <file>     # Sadece skor (pipe icin)

set -euo pipefail

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# === PATHS ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SCRIPT_DIR}/bridge.sh"

# === USAGE ===
usage() {
    cat <<EOF
${BOLD}eval.sh${NC} — Hybrid heuristic + LLM evaluation

${CYAN}Kullanim:${NC}
  eval.sh --layer1 <file>    Sadece heuristic check
  eval.sh --full <file>      Layer 1 + conditional Layer 2
  eval.sh --score <file>     Sadece skor ciktisi (pipe icin)

${CYAN}Verdicts:${NC}
  Layer 1: ACCEPT (>=80), GRAY_ZONE (40-79), REJECT (<40)
  Layer 2: ACCEPT (>=70), ACCEPT_FLAGGED (40-69), REJECT (<40)
EOF
    exit 1
}

# === ARGS ===
MODE=""
TARGET_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer1) MODE="layer1"; shift ;;
        --full)   MODE="full";   shift ;;
        --score)  MODE="score";  shift ;;
        -h|--help) usage ;;
        *)
            if [[ -z "$TARGET_FILE" ]]; then
                TARGET_FILE="$1"
            else
                echo -e "${RED}HATA: Beklenmeyen arguman: $1${NC}" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$MODE" ]] || [[ -z "$TARGET_FILE" ]]; then
    usage
fi

if [[ ! -f "$TARGET_FILE" ]]; then
    echo -e "${RED}HATA: Dosya bulunamadi: ${TARGET_FILE}${NC}" >&2
    exit 1
fi

# =============================================================================
# LAYER 1 — Heuristic Evaluation (Python)
# =============================================================================
run_layer1() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys
import json
import re
from collections import Counter

def evaluate(filepath):
    try:
        with open(filepath, "rb") as f:
            raw = f.read()
    except Exception as e:
        return {
            "layer": 1,
            "score": 0,
            "verdict": "REJECT",
            "checks": {"file_read": False},
            "deductions": [{"check": "file_read", "points": -100, "detail": str(e)}]
        }

    deductions = []
    checks = {}
    score = 100

    # --- Check 1: Encoding corruption (null bytes, high-byte sequences) ---
    null_count = raw.count(b"\x00")
    high_byte_count = sum(1 for b in raw if b > 127)
    has_corruption = null_count > 0 or (high_byte_count > len(raw) * 0.3 and len(raw) > 20)
    checks["encoding_corruption"] = not has_corruption
    if has_corruption:
        score -= 12
        detail = f"null_bytes={null_count}, high_bytes={high_byte_count}/{len(raw)}"
        deductions.append({"check": "encoding_corruption", "points": -12, "detail": detail})

    # Decode for text checks
    try:
        content = raw.decode("utf-8", errors="replace")
    except Exception:
        content = raw.decode("latin-1", errors="replace")

    content_stripped = content.strip()
    char_count = len(content_stripped)
    words = content_stripped.split()
    word_count = len(words)

    # --- Check 2: Empty output (< 10 chars) ---
    is_empty = char_count < 10
    checks["empty_output"] = not is_empty
    if is_empty:
        score -= 25
        deductions.append({"check": "empty_output", "points": -25, "detail": f"chars={char_count}"})

    # --- Check 3: Length bounds ---
    if word_count < 5 and not is_empty:
        checks["too_short"] = False
        score -= 12
        deductions.append({"check": "too_short", "points": -12, "detail": f"words={word_count}"})
    else:
        checks["too_short"] = True

    if word_count > 10000:
        checks["too_long"] = False
        score -= 8
        deductions.append({"check": "too_long", "points": -8, "detail": f"words={word_count}"})
    else:
        checks["too_long"] = True

    # --- Check 4: Repetitive content (3+ identical sentences) ---
    sentences = re.split(r'[.!?\n]+', content_stripped)
    sentences = [s.strip() for s in sentences if len(s.strip()) > 10]
    sentence_counts = Counter(sentences)
    repeated = {s: c for s, c in sentence_counts.items() if c >= 3}
    has_repetition = len(repeated) > 0
    checks["repetitive_content"] = not has_repetition
    if has_repetition:
        score -= 15
        top_repeat = max(repeated.items(), key=lambda x: x[1])
        deductions.append({
            "check": "repetitive_content",
            "points": -15,
            "detail": f"{len(repeated)} repeated sentence(s), worst: '{top_repeat[0][:60]}...' x{top_repeat[1]}"
        })

    # --- Check 5: Unresolved error patterns (2+ matches) ---
    error_patterns = [
        r'\bError:',
        r'\bException:',
        r'\bFAILED\b',
        r'\bTraceback\b',
        r'\bpanic:',
        r'\bFATAL\b'
    ]
    error_matches = 0
    matched_patterns = []
    for pat in error_patterns:
        found = re.findall(pat, content_stripped, re.IGNORECASE if pat in [r'\bFAILED\b', r'\bFATAL\b'] else 0)
        if found:
            error_matches += len(found)
            matched_patterns.append(f"{pat}({len(found)})")
    has_errors = error_matches >= 2
    checks["unresolved_errors"] = not has_errors
    if has_errors:
        score -= 15
        deductions.append({
            "check": "unresolved_errors",
            "points": -15,
            "detail": f"{error_matches} matches: {', '.join(matched_patterns)}"
        })

    # --- Check 6: Hallucination indicators ---
    halluc_patterns = [
        r"I don'?t have access",
        r"As an AI",
        r"my training data"
    ]
    halluc_matches = []
    for pat in halluc_patterns:
        if re.search(pat, content_stripped, re.IGNORECASE):
            halluc_matches.append(pat)
    has_halluc = len(halluc_matches) > 0
    checks["hallucination_indicators"] = not has_halluc
    if has_halluc:
        score -= 12
        deductions.append({
            "check": "hallucination_indicators",
            "points": -12,
            "detail": f"matched: {', '.join(halluc_matches)}"
        })

    # Clamp score
    score = max(0, min(100, score))

    # Verdict
    if score >= 80:
        verdict = "ACCEPT"
    elif score >= 40:
        verdict = "GRAY_ZONE"
    else:
        verdict = "REJECT"

    return {
        "layer": 1,
        "score": score,
        "verdict": verdict,
        "checks": checks,
        "deductions": deductions
    }

result = evaluate(sys.argv[1])
print(json.dumps(result))
PYEOF
}

# =============================================================================
# LAYER 2 — LLM Evaluation (via bridge.sh)
# =============================================================================
run_layer2() {
    local file="$1"
    local l1_score="$2"

    if [[ ! -x "$BRIDGE" ]]; then
        echo '{"error": "bridge.sh not found or not executable"}' >&2
        return 1
    fi

    # Ilk 2000 char'i al
    local content_preview
    content_preview="$(head -c 2000 "$file")"

    local prompt
    prompt="Evaluate this agent output for quality. Rate each dimension 0-10.

OUTPUT TO EVALUATE:
---
${content_preview}
---

Rate:
- relevance: How relevant and on-topic is the output? (0=completely off, 10=perfectly relevant)
- completeness: How complete is the response? (0=empty/stub, 10=thorough)
- accuracy: How accurate and factual does it appear? (0=wrong/hallucinated, 10=precise)

RESPOND WITH ONLY THIS JSON (no markdown, no explanation):
{\"relevance\": N, \"completeness\": N, \"accuracy\": N}"

    local llm_raw
    llm_raw="$("$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null)" || {
        echo '{"error": "bridge call failed"}' >&2
        return 1
    }

    # Parse LLM response with Python
    python3 - "$l1_score" <<PYEOF
import sys
import json
import re

l1_score = float(sys.argv[1])
llm_raw = """${llm_raw}"""

try:
    # JSON'i bul (bazen markdown wrapper olabiliyor)
    json_match = re.search(r'\{[^}]+\}', llm_raw)
    if not json_match:
        raise ValueError("No JSON found in LLM response")

    data = json.loads(json_match.group())
    r = float(data.get("relevance", 0))
    c = float(data.get("completeness", 0))
    a = float(data.get("accuracy", 0))

    # Clamp 0-10
    r = max(0, min(10, r))
    c = max(0, min(10, c))
    a = max(0, min(10, a))

    l2_score = (r * 0.4 + c * 0.3 + a * 0.3) * 10
    combined = l1_score * 0.4 + l2_score * 0.6

    if combined >= 70:
        verdict = "ACCEPT"
    elif combined >= 40:
        verdict = "ACCEPT_FLAGGED"
    else:
        verdict = "REJECT"

    result = {
        "layer": 2,
        "l1_score": l1_score,
        "l2_score": round(l2_score, 1),
        "l2_detail": {"relevance": r, "completeness": c, "accuracy": a},
        "combined_score": round(combined, 1),
        "verdict": verdict
    }
    print(json.dumps(result))

except Exception as e:
    print(json.dumps({"error": str(e), "raw": llm_raw[:200]}), file=sys.stderr)
    sys.exit(1)
PYEOF
}

# =============================================================================
# MAIN
# =============================================================================

# Run Layer 1
l1_json="$(run_layer1 "$TARGET_FILE")"
l1_score="$(echo "$l1_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['score'])")"
l1_verdict="$(echo "$l1_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])")"

# --score mode: just output the number
if [[ "$MODE" == "score" ]]; then
    if [[ "$l1_verdict" == "GRAY_ZONE" ]]; then
        # Full eval for accurate score
        l2_json="$(run_layer2 "$TARGET_FILE" "$l1_score" 2>/dev/null)" || true
        if [[ -n "$l2_json" ]]; then
            combined="$(echo "$l2_json" | python3 -c "import sys,json; print(int(json.load(sys.stdin).get('combined_score', $l1_score)))" 2>/dev/null)" || combined="$l1_score"
            echo "$combined"
        else
            echo "$l1_score"
        fi
    else
        echo "$l1_score"
    fi
    exit 0
fi

# --layer1 mode
if [[ "$MODE" == "layer1" ]]; then
    # Pretty print
    verdict_color="$GREEN"
    [[ "$l1_verdict" == "GRAY_ZONE" ]] && verdict_color="$YELLOW"
    [[ "$l1_verdict" == "REJECT" ]] && verdict_color="$RED"

    echo -e "${BOLD}=== Oracle Eval — Layer 1 (Heuristic) ===${NC}"
    echo -e "File:    ${CYAN}${TARGET_FILE}${NC}"
    echo -e "Score:   ${BOLD}${l1_score}${NC}/100"
    echo -e "Verdict: ${verdict_color}${l1_verdict}${NC}"

    # Deductions
    deduction_count="$(echo "$l1_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['deductions']))")"
    if [[ "$deduction_count" -gt 0 ]]; then
        echo -e "\n${YELLOW}Deductions:${NC}"
        echo "$l1_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for d in data['deductions']:
    print(f\"  {d['points']:+d}  {d['check']}: {d['detail']}\")
"
    else
        echo -e "\n${GREEN}No deductions — all checks passed.${NC}"
    fi

    echo ""
    echo "$l1_json"
    exit 0
fi

# --full mode
if [[ "$MODE" == "full" ]]; then
    verdict_color="$GREEN"
    [[ "$l1_verdict" == "GRAY_ZONE" ]] && verdict_color="$YELLOW"
    [[ "$l1_verdict" == "REJECT" ]] && verdict_color="$RED"

    echo -e "${BOLD}=== Oracle Eval — Full (Layer 1 + Layer 2) ===${NC}"
    echo -e "File:    ${CYAN}${TARGET_FILE}${NC}"
    echo -e "\n${BOLD}--- Layer 1 (Heuristic) ---${NC}"
    echo -e "Score:   ${BOLD}${l1_score}${NC}/100"
    echo -e "Verdict: ${verdict_color}${l1_verdict}${NC}"

    deduction_count="$(echo "$l1_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['deductions']))")"
    if [[ "$deduction_count" -gt 0 ]]; then
        echo -e "${YELLOW}Deductions:${NC}"
        echo "$l1_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for d in data['deductions']:
    print(f\"  {d['points']:+d}  {d['check']}: {d['detail']}\")
"
    fi

    if [[ "$l1_verdict" == "ACCEPT" ]]; then
        echo -e "\n${GREEN}Layer 1 ACCEPT — Layer 2 atlanıyor.${NC}"
        echo ""
        echo "$l1_json"
        exit 0
    fi

    if [[ "$l1_verdict" == "REJECT" ]]; then
        echo -e "\n${RED}Layer 1 REJECT — Layer 2 atlanıyor.${NC}"
        echo ""
        echo "$l1_json"
        exit 0
    fi

    # GRAY_ZONE → Layer 2
    echo -e "\n${YELLOW}GRAY_ZONE — Layer 2 (LLM) calistiriliyor...${NC}"

    l2_json="$(run_layer2 "$TARGET_FILE" "$l1_score" 2>/dev/null)" || l2_json=""

    if [[ -z "$l2_json" ]]; then
        echo -e "${RED}Layer 2 basarisiz — Layer 1 verdict kullaniliyor.${NC}"
        echo ""
        echo "$l1_json"
        exit 0
    fi

    # Parse Layer 2 result
    l2_combined="$(echo "$l2_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('combined_score', 0))" 2>/dev/null)" || l2_combined="0"
    l2_verdict="$(echo "$l2_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('verdict', 'UNKNOWN'))" 2>/dev/null)" || l2_verdict="UNKNOWN"
    l2_score_raw="$(echo "$l2_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('l2_score', 0))" 2>/dev/null)" || l2_score_raw="0"

    final_color="$GREEN"
    [[ "$l2_verdict" == "ACCEPT_FLAGGED" ]] && final_color="$YELLOW"
    [[ "$l2_verdict" == "REJECT" ]] && final_color="$RED"

    echo -e "\n${BOLD}--- Layer 2 (LLM) ---${NC}"
    echo -e "L2 Score: ${BOLD}${l2_score_raw}${NC}/100"

    echo "$l2_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
d = data.get('l2_detail', {})
print(f\"  Relevance:    {d.get('relevance', '?')}/10\")
print(f\"  Completeness: {d.get('completeness', '?')}/10\")
print(f\"  Accuracy:     {d.get('accuracy', '?')}/10\")
" 2>/dev/null || true

    echo -e "\n${BOLD}--- Combined ---${NC}"
    echo -e "Combined: ${BOLD}${l2_combined}${NC}/100  (L1*0.4 + L2*0.6)"
    echo -e "Verdict:  ${final_color}${l2_verdict}${NC}"
    echo ""
    echo "$l2_json"
    exit 0
fi
