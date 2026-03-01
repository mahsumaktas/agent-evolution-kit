#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# bridge.sh — Nested LLM CLI wrapper with presets, budget control, and logging
#
# Wraps any LLM CLI (e.g. Claude CLI) with configurable presets, cost tracking,
# and trajectory pool integration for the self-evolution loop.
#
# Usage:
#   bridge.sh [options] "prompt"
#
# Examples:
#   bridge.sh "Analyze this PR"
#   bridge.sh --research "Deep dive into recent AI developments"
#   bridge.sh --quick "What is the capital of France?"
#   bridge.sh --json-schema '{"type":"object"}' "Give structured output"

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

# CLI binary — set CLI_BIN to your LLM CLI path (e.g. claude, llm, etc.)
CLI_BIN="${CLI_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
if [[ ! -x "$CLI_BIN" ]]; then
    echo "[bridge] ERROR: LLM CLI not found at: $CLI_BIN" >&2
    echo "[bridge] Set CLI_BIN to the path of your LLM CLI tool." >&2
    exit 127
fi

# === Defaults ===
MODEL="sonnet"
MAX_TURNS=25
BUDGET="1.00"
OUTPUT_FORMAT="json"
TIMEOUT=300
EXTRA_DIRS=""
SYSTEM_PROMPT=""
JSON_SCHEMA=""
PERMISSION_MODE="dangerously-skip-permissions"
SESSION_PERSIST="--no-session-persistence"
LOG_DIR="$AEK_HOME/memory/bridge-logs"
TRAJECTORY_FILE="$AEK_HOME/memory/trajectory-pool.json"
COST_LOG="$AEK_HOME/memory/cost-log.jsonl"

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === Functions ===
log() { echo -e "${GREEN}[bridge]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[bridge]${NC} $1" >&2; }
err() { echo -e "${RED}[bridge]${NC} $1" >&2; }

usage() {
    cat >&2 << 'EOF'
bridge.sh — LLM CLI Bridge with Presets

Usage: bridge.sh [options] "prompt"

Options:
  --model <model>        Model selection: opus, sonnet, haiku (default: sonnet)
  --max-turns <N>        Maximum turn count (default: 25)
  --budget <USD>         Maximum budget in USD (default: 1.00)
  --timeout <seconds>    Timeout in seconds (default: 300)
  --output text|json     Output format (default: json)
  --add-dir <path>       Additional directory access
  --system-prompt <str>  Custom system prompt
  --json-schema <json>   JSON schema for structured output
  --persist              Persist session (for resume)
  --text                 Text output (shorthand for --output text)
  --silent               Suppress log messages
  --dry-run              Show command without executing

Presets:
  --research             Deep research mode (opus, 50 turns, $2.00 budget)
  --quick                Quick query mode (haiku, 3 turns, $0.10 budget)
  --code                 Code generation mode (sonnet, 30 turns, $1.50 budget)
  --analyze              Analysis mode (opus, 20 turns, $1.00 budget)
  --tool-gen             Tool generation mode (sonnet, 40 turns, $2.00 budget)
  --system               System management mode (sonnet, 15 turns, $0.50 budget)

Environment Variables:
  AEK_HOME               Kit root directory (default: ~/agent-evolution-kit)
  CLI_BIN                Path to LLM CLI binary (default: auto-detect claude)
  BRIDGE_CALLER          Caller identifier for cost log (default: manual)
EOF
    exit 1
}

# === Parse Arguments ===
SILENT=false
DRY_RUN=false
PROMPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)         MODEL="$2"; shift 2;;
        --max-turns)     MAX_TURNS="$2"; shift 2;;
        --budget)        BUDGET="$2"; shift 2;;
        --timeout)       TIMEOUT="$2"; shift 2;;
        --output)        OUTPUT_FORMAT="$2"; shift 2;;
        --add-dir)       EXTRA_DIRS="$EXTRA_DIRS --add-dir $2"; shift 2;;
        --system-prompt) SYSTEM_PROMPT="$2"; shift 2;;
        --json-schema)   JSON_SCHEMA="$2"; shift 2;;
        --persist)       SESSION_PERSIST=""; shift;;
        --text)          OUTPUT_FORMAT="text"; shift;;
        --silent)        SILENT=true; shift;;
        --dry-run)       DRY_RUN=true; shift;;
        # Presets
        --research)      MODEL="opus"; MAX_TURNS=50; BUDGET="2.00"; shift;;
        --quick)         MODEL="haiku"; MAX_TURNS=3; BUDGET="0.10"; shift;;
        --code)          MODEL="sonnet"; MAX_TURNS=30; BUDGET="1.50"; shift;;
        --analyze)       MODEL="opus"; MAX_TURNS=20; BUDGET="1.00"; shift;;
        --tool-gen)      MODEL="sonnet"; MAX_TURNS=40; BUDGET="2.00"; shift;;
        --system)        MODEL="sonnet"; MAX_TURNS=15; BUDGET="0.50"; shift;;
        --help|-h)       usage;;
        -*)              err "Unknown option: $1"; usage;;
        *)               PROMPT="$1"; shift;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    # Check if prompt comes from stdin
    if [[ ! -t 0 ]]; then
        PROMPT=$(cat)
    else
        err "Prompt required"
        usage
    fi
fi

# === Build Command ===
CMD=(env -u CLAUDECODE "$CLI_BIN" -p "$PROMPT"
    --model "$MODEL"
    --max-turns "$MAX_TURNS"
    --max-budget-usd "$BUDGET"
    --output-format "$OUTPUT_FORMAT"
    --"$PERMISSION_MODE"
    --add-dir "$AEK_HOME"
)

[[ -n "$SESSION_PERSIST" ]] && CMD+=($SESSION_PERSIST)
[[ -n "$SYSTEM_PROMPT" ]] && CMD+=(--system-prompt "$SYSTEM_PROMPT")
[[ -n "$JSON_SCHEMA" ]] && CMD+=(--json-schema "$JSON_SCHEMA")
[[ -n "$EXTRA_DIRS" ]] && eval "CMD+=($EXTRA_DIRS)"

# === Dry Run ===
if $DRY_RUN; then
    echo "${CMD[@]}"
    exit 0
fi

# === Execute ===
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$COST_LOG")"
mkdir -p "$(dirname "$TRAJECTORY_FILE")"

START_TIME=$(date +%s)
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S%z)
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$(echo "$MODEL" | head -c3).json"

$SILENT || log "Model: $MODEL | Turns: $MAX_TURNS | Budget: \$$BUDGET | Timeout: ${TIMEOUT}s"

# Run with timeout (macOS: perl fallback, Linux: coreutils timeout)
_run_with_timeout() {
    if command -v timeout &>/dev/null; then
        timeout "$1" "${@:2}"
    else
        perl -e 'alarm shift; exec @ARGV' "$@"
    fi
}

RESULT=$(_run_with_timeout "$TIMEOUT" "${CMD[@]}" 2>/dev/null) || {
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 142 || $EXIT_CODE -eq 124 ]]; then
        err "Timeout after ${TIMEOUT}s"
    else
        err "CLI exited with code: $EXIT_CODE"
    fi
    # Log failure
    echo "{\"timestamp\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"status\":\"FAILED\",\"exit_code\":$EXIT_CODE,\"prompt\":\"$(echo "$PROMPT" | head -c200)\"}" > "$LOG_FILE"
    # Cost log (failure)
    echo "{\"ts\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration\":0,\"cost\":\"0\",\"turns\":\"0\",\"status\":\"FAILED\",\"caller\":\"${BRIDGE_CALLER:-manual}\"}" >> "$COST_LOG"
    exit $EXIT_CODE
}

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# === Output ===
echo "$RESULT"

# === Log ===
COST="0"
TURNS="1"
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Extract metadata from JSON result
    COST=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_cost_usd',0))" 2>/dev/null || echo "0")
    TURNS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('num_turns',0))" 2>/dev/null || echo "1")
    $SILENT || log "Completed: ${DURATION}s | Cost: \$${COST} | Turns: $TURNS"

    # Save full log
    echo "$RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
data['_bridge_meta'] = {
    'timestamp': '$TIMESTAMP',
    'duration_s': $DURATION,
    'prompt_preview': '''$(echo "$PROMPT" | head -c200)''',
    'preset': 'custom'
}
json.dump(data, sys.stdout, indent=2)
" > "$LOG_FILE" 2>/dev/null || true
else
    $SILENT || log "Completed: ${DURATION}s"
    echo "{\"timestamp\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration_s\":$DURATION,\"status\":\"SUCCESS\",\"prompt\":\"$(echo "$PROMPT" | head -c200)\"}" > "$LOG_FILE"
fi

# === Cost Log (append-only JSONL) ===
COST_ENTRY="{\"ts\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration\":$DURATION,\"cost\":\"${COST:-0}\",\"turns\":\"${TURNS:-1}\",\"status\":\"SUCCESS\",\"caller\":\"${BRIDGE_CALLER:-manual}\"}"
echo "$COST_ENTRY" >> "$COST_LOG"

# === Trajectory Pool (append entry for self-evolution tracking) ===
python3 - "$TRAJECTORY_FILE" "$TIMESTAMP" "$MODEL" "$DURATION" "${COST:-0}" "${TURNS:-1}" "${BRIDGE_CALLER:-manual}" "$(echo "$PROMPT" | head -c200)" <<'PYEOF'
import json, sys, os
path, ts, model, dur, cost, turns, caller, prompt = sys.argv[1:9]
pool = []
if os.path.exists(path):
    try:
        with open(path) as f: pool = json.load(f)
    except: pool = []
entry = {"id": len(pool)+1, "timestamp": ts, "agent": "bridge", "task": prompt,
         "model": model, "duration_s": int(dur), "cost_usd": float(cost),
         "turns": int(turns), "caller": caller, "result": "success"}
pool.append(entry)
if len(pool) > 100: pool = pool[-100:]
with open(path, 'w') as f: json.dump(pool, f, indent=2, ensure_ascii=False)
PYEOF
