#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# maker-checker.sh — Maker-Checker dual verification loop
# Sends maker output to a checker agent, runs APPROVE/ISSUE/REJECT loop.
#
# Usage:
#   maker-checker.sh --maker <agent> --checker <agent> --task "desc" --input <file>
#   maker-checker.sh --auto --maker <agent> --task "desc" --input <file>

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

# === PATHS ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/bridge.sh"
CONFIG="$AEK_HOME/config/maker-checker-pairs.yaml"
TRAJECTORY_FILE="$AEK_HOME/memory/trajectory-pool.json"

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
Maker-Checker — Dual verification loop

Usage:
  maker-checker.sh --maker <agent> --checker <agent> --task "desc" --input <file>
  maker-checker.sh --auto --maker <agent> --task "desc" --input <file>

Options:
  --maker <agent>     Maker agent name
  --checker <agent>   Checker agent name (auto-selected with --auto)
  --auto              Auto-select checker from config
  --task "desc"       Task description
  --input <file>      File containing maker output
  --max-iter <N>      Maximum iterations (default: 3)
  --help              Show this message
EOF
    exit 1
}

# === AUTO-SELECT CHECKER ===
# Parses YAML with Python (no pyyaml dependency — line-by-line parsing)
auto_select_checker() {
    local maker="$1"
    local task="$2"
    local config_file="$3"

    if [[ ! -f "$config_file" ]]; then
        err "Config file not found: $config_file"
        echo "default"
        return
    fi

    python3 - "$maker" "$task" "$config_file" <<'PYEOF'
import sys

maker = sys.argv[1]
task_desc = sys.argv[2].lower()
config_path = sys.argv[3]

# Parse YAML line by line — simple pairs list
pairs = []
current = {}
in_pairs = False

with open(config_path) as f:
    for line in f:
        stripped = line.strip()
        # Comment or empty line
        if not stripped or stripped.startswith('#'):
            continue
        if stripped == 'pairs:':
            in_pairs = True
            continue
        if not in_pairs:
            continue

        # New pair start
        if stripped.startswith('- maker:'):
            if current:
                pairs.append(current)
            current = {'maker': stripped.split(':', 1)[1].strip().strip('"').strip("'")}
        elif stripped.startswith('checker:'):
            current['checker'] = stripped.split(':', 1)[1].strip().strip('"').strip("'")
        elif stripped.startswith('domains:'):
            # Parse [blog, documentation, report, content] format
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
        # Exact maker match but no domain match — still a candidate
        if not best and pair.get('maker') != '*':
            best = pair

# 2. Wildcard fallback
if not best:
    for pair in pairs:
        if pair.get('maker') == '*':
            best = pair
            break

# 3. Nothing matched
if not best:
    print('default')
else:
    print(best.get('checker', 'default'))
PYEOF
}

# === TRAJECTORY UPDATE ===
update_trajectory_checker() {
    local checker="$1"
    local result="$2"
    local iterations="$3"

    if [[ ! -f "$TRAJECTORY_FILE" ]]; then
        warn "Trajectory file not found, skipping update"
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

# Dict format — entries under "entries" key
if isinstance(data, dict):
    entries = data.get("entries", [])
elif isinstance(data, list):
    entries = data
else:
    sys.exit(0)

# Update last entry
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
        *)          err "Unknown parameter: $1"; usage;;
    esac
done

# === VALIDATION ===
if [[ -z "$MAKER" ]]; then
    err "--maker parameter is required"
    usage
fi
if [[ -z "$TASK" ]]; then
    err "--task parameter is required"
    usage
fi
if [[ -z "$INPUT_FILE" ]]; then
    err "--input parameter is required"
    usage
fi
if [[ ! -f "$INPUT_FILE" ]]; then
    err "Input file not found: $INPUT_FILE"
    exit 1
fi
if [[ ! -x "$BRIDGE" ]]; then
    err "Bridge script not found or not executable: $BRIDGE"
    exit 1
fi

# === AUTO-SELECT CHECKER ===
if [[ "$AUTO" == true ]]; then
    CHECKER="$(auto_select_checker "$MAKER" "$TASK" "$CONFIG")"
    log "Auto-selected checker: $CHECKER"
elif [[ -z "$CHECKER" ]]; then
    err "--checker or --auto parameter required"
    usage
fi

# === READ INPUT ===
CONTENT="$(cat "$INPUT_FILE")"
if [[ -z "$CONTENT" ]]; then
    err "Input file is empty: $INPUT_FILE"
    exit 1
fi

log "Maker: $MAKER | Checker: $CHECKER | Task: $TASK"
log "Max iterations: $MAX_ITER"
info "Input size: $(wc -c < "$INPUT_FILE" | tr -d ' ') bytes"

# === MAIN LOOP ===
CURRENT_CONTENT="$CONTENT"
ITERATION=0
FINAL_RESULT="ISSUE"

while [[ $ITERATION -lt $MAX_ITER ]]; do
    ITERATION=$((ITERATION + 1))
    log "--- Iteration $ITERATION/$MAX_ITER ---"

    # Limit content to 3000 chars for checker prompt
    CONTENT_TRIMMED="$(echo "$CURRENT_CONTENT" | head -c 3000)"

    # Build checker prompt
    CHECKER_PROMPT="You are a checker reviewing work by ${MAKER}.
Task: ${TASK}

Review this output and respond with EXACTLY one of:
- APPROVE: [brief reason]
- ISSUE: [specific feedback]
- REJECT: [reason]

Output to review:
${CONTENT_TRIMMED}"

    # Send to checker
    log "Sending to checker ($CHECKER)..."
    CHECKER_RESPONSE_FILE="$(make_temp)"

    if ! "$BRIDGE" --quick --text --silent "$CHECKER_PROMPT" > "$CHECKER_RESPONSE_FILE" 2>/dev/null; then
        warn "Bridge call failed — accepting maker output (fallback)"
        FINAL_RESULT="APPROVE-FALLBACK"
        break
    fi

    CHECKER_RESPONSE="$(cat "$CHECKER_RESPONSE_FILE")"

    if [[ -z "$CHECKER_RESPONSE" ]]; then
        warn "Checker returned empty response — accepting maker output (fallback)"
        FINAL_RESULT="APPROVE-FALLBACK"
        break
    fi

    # Parse response
    if echo "$CHECKER_RESPONSE" | grep -qi "^APPROVE"; then
        log "Checker APPROVE"
        FINAL_RESULT="APPROVE"
        break
    elif echo "$CHECKER_RESPONSE" | grep -qi "^REJECT"; then
        REJECT_REASON="$(echo "$CHECKER_RESPONSE" | grep -oi "^REJECT:.*" | head -1)"
        err "Checker REJECT: $REJECT_REASON"
        FINAL_RESULT="REJECT"
        break
    elif echo "$CHECKER_RESPONSE" | grep -qi "^ISSUE"; then
        FEEDBACK="$(echo "$CHECKER_RESPONSE" | grep -oi "^ISSUE:.*" | head -1)"
        warn "Checker ISSUE: $FEEDBACK"

        if [[ $ITERATION -ge $MAX_ITER ]]; then
            warn "Max iterations reached — accepting last version"
            FINAL_RESULT="ISSUE-MAX-ITER"
            break
        fi

        # Send to maker for revision
        log "Sending to maker ($MAKER) for revision..."
        CONTENT_FOR_REVISION="$(echo "$CURRENT_CONTENT" | head -c 2000)"

        REVISION_PROMPT="Your previous output was reviewed and needs improvement.
Task: ${TASK}
Feedback: ${FEEDBACK}
Original output: ${CONTENT_FOR_REVISION}

Revise your output addressing the feedback."

        REVISION_FILE="$(make_temp)"

        if ! "$BRIDGE" --quick --text --silent "$REVISION_PROMPT" > "$REVISION_FILE" 2>/dev/null; then
            warn "Revision bridge call failed — continuing with current version"
            continue
        fi

        REVISED="$(cat "$REVISION_FILE")"
        if [[ -n "$REVISED" ]]; then
            CURRENT_CONTENT="$REVISED"
            info "Revision received ($(echo "$REVISED" | wc -c | tr -d ' ') bytes)"
        else
            warn "Empty revision returned — continuing with current version"
        fi
    else
        # None of the expected formats matched — check full response
        if echo "$CHECKER_RESPONSE" | grep -qi "approve"; then
            log "Checker APPROVE (inline)"
            FINAL_RESULT="APPROVE"
            break
        elif echo "$CHECKER_RESPONSE" | grep -qi "reject"; then
            err "Checker REJECT (inline)"
            FINAL_RESULT="REJECT"
            break
        else
            warn "Could not parse checker response — accepting maker output (fallback)"
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
    log "Trajectory updated: checker=$CHECKER, result=$FINAL_RESULT, iterations=$ITERATION"
fi

# === SUMMARY ===
log "=== Result ==="
log "  Maker: $MAKER"
log "  Checker: $CHECKER"
log "  Iterations: $ITERATION/$MAX_ITER"
log "  Result: $FINAL_RESULT"

case "$FINAL_RESULT" in
    APPROVE)          exit 0;;
    APPROVE-FALLBACK) exit 0;;
    ISSUE-MAX-ITER)   warn "Max iteration warning — last version used"; exit 0;;
    REJECT)           err "Rejected by checker"; exit 1;;
    *)                exit 1;;
esac
