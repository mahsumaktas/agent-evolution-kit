#!/usr/bin/env bash
# Oracle Claude Bridge — Oracle'in tam guc erisim koprusu
# Oracle bu script uzerinden Claude Code CLI'a erisir.
# Kullanim: bridge.sh [options] "prompt"
#
# Ornekler:
#   bridge.sh "Bu PR'i analiz et"
#   bridge.sh --model opus --budget 0.50 "Derin arastirma yap"
#   bridge.sh --json-schema '{"type":"object"}' "Yapisal cikti ver"
#   bridge.sh --tool-gen "CSV parser scripti yaz"
#   bridge.sh --research "Son AI gelismeleri"

set -euo pipefail

# === CLAUDE CLI PATH ===
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "[bridge] HATA: claude CLI bulunamadi. PATH: $CLAUDE_BIN" >&2
    exit 127
fi

# === DEFAULTS ===
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
LOG_DIR="$HOME/clawd/memory/bridge-logs"
TRAJECTORY_FILE="$HOME/clawd/memory/trajectory-pool.json"
CB_SCRIPT="$HOME/clawd/scripts/circuit-breaker.sh"
REPLAY_ENABLED="${REPLAY_ENABLED:-true}"
EVAL_ENABLED="${EVAL_ENABLED:-false}"
ORACLE_PRIORITY="${ORACLE_PRIORITY:-}"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === FUNCTIONS ===
log() { echo -e "${GREEN}[bridge]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[bridge]${NC} $1" >&2; }
err() { echo -e "${RED}[bridge]${NC} $1" >&2; }

# Trajectory pool'a entry ekle — dict format ({entries:[...]}) ve flat list destekler
append_trajectory() {
    local exit_code="$1" cost="${2:-0}" turns="${3:-1}"
    local prompt_short
    prompt_short="$(echo "$PROMPT" | head -c200)"
    python3 - "$TRAJECTORY_FILE" "$TIMESTAMP" "$MODEL" "${DURATION:-0}" "$cost" "$turns" \
        "${ORACLE_CALLER:-manual}" "$prompt_short" "$exit_code" <<'PYEOF'
import json, sys, os

path, ts, model, dur, cost, turns, caller, prompt, exit_code = sys.argv[1:10]

result = "success" if exit_code == "0" else "failure"

# Dosyayi oku — dict veya flat list olabilir
schema_meta = {}
entries = []
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(data, dict):
            entries = data.get("entries", [])
            schema_meta = {k: v for k, v in data.items() if k != "entries"}
        elif isinstance(data, list):
            entries = data
    except (json.JSONDecodeError, ValueError):
        entries = []

# Yeni entry
entry = {
    "id": f"traj-{len(entries)+1:03d}",
    "timestamp": ts,
    "agent": "bridge",
    "task": prompt,
    "model": model,
    "duration_s": int(dur),
    "cost_usd": float(cost),
    "turns": int(turns),
    "caller": caller,
    "result": result,
    "task_type": os.environ.get("ORACLE_TASK_TYPE", "general")
}
eval_sc = os.environ.get("BRIDGE_EVAL_SCORE", "")
if eval_sc and eval_sc.isdigit():
    entry["eval_score"] = int(eval_sc)
priority = os.environ.get("ORACLE_PRIORITY", "")
if priority:
    entry["priority"] = priority
entries.append(entry)

# Son 100 entry tut
if len(entries) > 100:
    entries = entries[-100:]

# Schema meta varsa koru, yoksa varsayilan ekle
if not schema_meta:
    schema_meta = {
        "_schema_version": "1.0",
        "_description": "Oracle trajectory pool — her agent gorevinin yapisal kaydini tutar",
        "_max_entries": 100,
        "_archive_after_weeks": 4
    }

output = {**schema_meta, "entries": entries}
with open(path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
PYEOF
}

usage() {
    cat >&2 << 'EOF'
Oracle Claude Bridge — Tam guc erisim

Kullanim: bridge.sh [options] "prompt"

Secenekler:
  --model <model>        Model secimi: opus, sonnet, haiku (default: sonnet)
  --max-turns <N>        Maksimum tur sayisi (default: 25)
  --budget <USD>         Maksimum butce (default: 1.00)
  --timeout <saniye>     Zaman asimi (default: 300)
  --output text|json     Cikti formati (default: json)
  --add-dir <path>       Ek dizin erisimi
  --system-prompt <str>  Ozel sistem prompt'u
  --json-schema <json>   JSON schema (yapisal cikti icin)
  --persist              Session'i kaydet (resume icin)
  --text                 text output (json yerine)
  --silent               Log mesajlarini gizle
  --dry-run              Komutu goster, calistirma

Presetler:
  --research             Derin arastirma modu (opus, 50 turn, 2.00 butce)
  --quick                Hizli sorgu modu (haiku, 3 turn, 0.10 butce)
  --code                 Kod uretimi modu (sonnet, 30 turn, 1.50 butce)
  --analyze              Analiz modu (opus, 20 turn, 1.00 butce)
  --tool-gen             Tool uretimi modu (sonnet, 40 turn, 2.00 butce)
  --system               Sistem yonetimi modu (sonnet, 15 turn, 0.50 butce)
EOF
    exit 1
}

# === PARSE ARGS ===
SILENT=false
DRY_RUN=false
PROMPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)     MODEL="$2"; shift 2;;
        --max-turns) MAX_TURNS="$2"; shift 2;;
        --budget)    BUDGET="$2"; shift 2;;
        --timeout)   TIMEOUT="$2"; shift 2;;
        --output)    OUTPUT_FORMAT="$2"; shift 2;;
        --add-dir)   EXTRA_DIRS="$EXTRA_DIRS --add-dir $2"; shift 2;;
        --system-prompt) SYSTEM_PROMPT="$2"; shift 2;;
        --json-schema)   JSON_SCHEMA="$2"; shift 2;;
        --persist)   SESSION_PERSIST=""; shift;;
        --text)      OUTPUT_FORMAT="text"; shift;;
        --silent)    SILENT=true; shift;;
        --dry-run)   DRY_RUN=true; shift;;
        # Presets
        --research)  MODEL="opus"; MAX_TURNS=50; BUDGET="2.00"; EVAL_ENABLED=true; shift;;
        --quick)     MODEL="haiku"; MAX_TURNS=3; BUDGET="0.10"; shift;;
        --code)      MODEL="sonnet"; MAX_TURNS=30; BUDGET="1.50"; EVAL_ENABLED=true; shift;;
        --analyze)   MODEL="opus"; MAX_TURNS=20; BUDGET="1.00"; EVAL_ENABLED=true; shift;;
        --tool-gen)  MODEL="sonnet"; MAX_TURNS=40; BUDGET="2.00"; EVAL_ENABLED=true; shift;;
        --system)    MODEL="sonnet"; MAX_TURNS=15; BUDGET="0.50"; shift;;
        --replay)    REPLAY_ENABLED=true; shift;;
        --no-replay) REPLAY_ENABLED=false; shift;;
        --eval)      EVAL_ENABLED=true; shift;;
        --no-eval)   EVAL_ENABLED=false; shift;;
        --priority)  ORACLE_PRIORITY="$2"; shift 2;;
        --help|-h)   usage;;
        -*)          err "Bilinmeyen secenek: $1"; usage;;
        *)           PROMPT="$1"; shift;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    # Check if prompt comes from stdin
    if [[ ! -t 0 ]]; then
        PROMPT=$(cat)
    else
        err "Prompt gerekli"
        usage
    fi
fi

# === REPLAY INJECTION (before CMD build so enriched PROMPT is captured) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLAY_SCRIPT="$SCRIPT_DIR/replay.sh"
if [[ "$REPLAY_ENABLED" == "true" && -x "$REPLAY_SCRIPT" ]]; then
    TASK_TYPE="${ORACLE_TASK_TYPE:-general}"
    REPLAY_CTX=$("$REPLAY_SCRIPT" --task-type "$TASK_TYPE" --max 2 --inject 2>/dev/null) || true
    if [[ -n "$REPLAY_CTX" ]]; then
        PROMPT="${PROMPT}

## Past Experience (Similar Tasks)
${REPLAY_CTX}"
        $SILENT || log "Replay: ${#REPLAY_CTX} karakter enjekte edildi"
    fi
fi

# === ORACLE IDENTITY INJECTION ===
IDENTITY_FILE="$HOME/clawd/scripts/identity-prompt.txt"
if [[ -z "$SYSTEM_PROMPT" && -f "$IDENTITY_FILE" ]]; then
    IDENTITY_PROMPT=$(cat "$IDENTITY_FILE")
fi

# === BUILD COMMAND ===
CMD=(env -u CLAUDECODE "$CLAUDE_BIN" -p "$PROMPT"
    --model "$MODEL"
    --max-turns "$MAX_TURNS"
    --max-budget-usd "$BUDGET"
    --output-format "$OUTPUT_FORMAT"
    --"$PERMISSION_MODE"
    --add-dir "$HOME/clawd"
    --add-dir "$HOME"
)

[[ -n "$SESSION_PERSIST" ]] && CMD+=($SESSION_PERSIST)
if [[ -n "$SYSTEM_PROMPT" ]]; then
    CMD+=(--system-prompt "$SYSTEM_PROMPT")
elif [[ -n "${IDENTITY_PROMPT:-}" ]]; then
    CMD+=(--append-system-prompt "$IDENTITY_PROMPT")
fi
[[ -n "$JSON_SCHEMA" ]] && CMD+=(--json-schema "$JSON_SCHEMA")
[[ -n "$EXTRA_DIRS" ]] && eval "CMD+=($EXTRA_DIRS)"

# === DRY RUN ===
if $DRY_RUN; then
    echo "${CMD[@]}"
    exit 0
fi

# === CIRCUIT BREAKER CHECK ===
CB_CALLER="${ORACLE_CALLER:-manual}"
if [[ -x "$CB_SCRIPT" ]]; then
    if ! "$CB_SCRIPT" check "$CB_CALLER" >/dev/null 2>&1; then
        err "Circuit breaker OPEN: $CB_CALLER engellendi. 'circuit-breaker.sh reset $CB_CALLER' ile sifirlayabilirsiniz."
        exit 2
    fi
fi

# === GOVERNANCE CHECK ===
GOVERNANCE_SCRIPT="$SCRIPT_DIR/governance.sh"
if [[ -x "$GOVERNANCE_SCRIPT" ]]; then
    GOV_RESULT=$("$GOVERNANCE_SCRIPT" check "$CB_CALLER" "execute" 2>/dev/null) || true
    if [[ "$GOV_RESULT" == *"BLOCKED"* ]]; then
        err "Governance blocked: $GOV_RESULT"
        exit 3
    fi
    $SILENT || [[ -z "$GOV_RESULT" ]] || log "Governance: $GOV_RESULT"
fi

# === PRIORITY ASSIGNMENT ===
if [[ -z "$ORACLE_PRIORITY" ]]; then
    PRIORITY_CONFIG="$HOME/clawd/config/priority-rules.yaml"
    if [[ -f "$PRIORITY_CONFIG" ]] && command -v python3 &>/dev/null; then
        ORACLE_PRIORITY=$(python3 - "$PRIORITY_CONFIG" "$PROMPT" <<'PYEOF'
import sys, re

config_file, prompt = sys.argv[1], sys.argv[2].lower()
# Simple YAML parser for priority-rules.yaml structure
current_level = None
level_keywords = {}
with open(config_file) as f:
    for line in f:
        stripped = line.strip()
        m = re.match(r'^(P\d):', stripped)
        if m:
            current_level = m.group(1)
            level_keywords[current_level] = []
            continue
        if current_level and stripped.startswith("keywords:"):
            kws = re.findall(r'[\w-]+', stripped.replace("keywords:", ""))
            level_keywords[current_level] = kws

# P2 omitted — it's the default when no keyword matches
for level in ["P0", "P1", "P3", "P4"]:
    for kw in level_keywords.get(level, []):
        pattern = re.compile(r'\b' + re.escape(kw.lower()) + r'\b')
        if pattern.search(prompt):
            print(level)
            sys.exit(0)
print("P2")
PYEOF
        ) || ORACLE_PRIORITY="P2"
    else
        ORACLE_PRIORITY="P2"
    fi
fi
export ORACLE_PRIORITY
$SILENT || log "Priority: $ORACLE_PRIORITY"

# === EXECUTE ===
mkdir -p "$LOG_DIR"
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

# === REFLEXION TRIGGER (post-failure hook) ===
# Basarisiz gorevlerde oz-degerlendirme + MARS metacognitive extraction yapar.
# Hic bir hata bridge'in tamamlanmasini engellemez (|| true ile sarili).
_reflexion_trigger() {
    local exit_code="$1"
    local caller="${ORACLE_CALLER:-manual}"
    local safe_caller
    safe_caller="$(echo "$caller" | sed 's/[^a-zA-Z0-9_-]/-/g' | head -c30)"
    local reflect_dir="$HOME/clawd/memory/reflections/$safe_caller"
    local principles_dir="$HOME/clawd/memory/principles"
    local today
    today="$(date +%Y-%m-%d)"
    local reflect_file="$reflect_dir/${today}-${safe_caller}.md"
    local principles_file="$principles_dir/${safe_caller}.md"
    local task_prompt_short
    task_prompt_short="$(echo "$PROMPT" | head -c200)"
    local error_tail
    error_tail="$(echo "$RESULT" | tail -c500)"

    # Claude CLI kullanilabilir mi?
    if [[ ! -x "$CLAUDE_BIN" ]]; then
        return 0
    fi

    # Cooldown: ayni agent son 60 dakikada reflect ettiyse atla
    mkdir -p "$reflect_dir"
    if [[ -n "$(find "$reflect_dir" -name '*.md' -mmin -60 2>/dev/null)" ]]; then
        $SILENT || log "Reflexion cooldown aktif ($safe_caller), atlaniyor."
        return 0
    fi

    $SILENT || log "Reflexion trigger calisiyor ($safe_caller)..."

    # --- Step 1: Reflection ---
    local reflection_prompt
    reflection_prompt="A task just failed. Analyze concisely.
Agent: ${caller}
Task: ${task_prompt_short}
Exit code: ${exit_code}
Error (last 500 chars): ${error_tail}

Format:
## What happened
[2-3 sentences]
## Root cause
[1-2 sentences]
## Lesson
[1 actionable sentence]"

    local reflection
    reflection="$(env -u CLAUDECODE "$CLAUDE_BIN" -p --model haiku --max-tokens 300 "$reflection_prompt" 2>/dev/null)" || {
        $SILENT || warn "Reflexion cagrisi basarisiz."
        return 0
    }

    if [[ -z "$reflection" ]]; then
        $SILENT || warn "Reflexion bos cikti."
        return 0
    fi

    # Reflection'i kaydet
    {
        echo "# Reflexion: ${caller} — ${today}"
        echo ""
        echo "**Task:** ${task_prompt_short}"
        echo "**Exit code:** ${exit_code}"
        echo "**Model:** ${MODEL}"
        echo ""
        echo "$reflection"
    } > "$reflect_file"

    $SILENT || log "Reflection kaydedildi: $reflect_file"

    # --- Step 2: MARS metacognitive extraction ---
    local mars_prompt
    mars_prompt="From this reflection, extract:
PRINCIPLE: A normative rule \"Always X when Y because Z\" or \"Never X when Y because Z\"
PROCEDURE: Steps taken, numbered (Step 1: ..., Step 2: ...)

Respond ONLY with:
PRINCIPLE: [rule]
PROCEDURE:
1. [step]
2. [step]

Reflection:
${reflection}"

    local mars_result
    mars_result="$(env -u CLAUDECODE "$CLAUDE_BIN" -p --model haiku --max-tokens 300 "$mars_prompt" 2>/dev/null)" || {
        $SILENT || warn "MARS extraction cagrisi basarisiz."
        return 0
    }

    if [[ -z "$mars_result" ]]; then
        $SILENT || warn "MARS extraction bos cikti."
        return 0
    fi

    # MARS sonucunu reflection dosyasina ekle
    {
        echo ""
        echo "---"
        echo "## MARS Extraction"
        echo ""
        echo "$mars_result"
    } >> "$reflect_file"

    # Principle'i ayri dosyaya kaydet (append)
    local principle_line
    principle_line="$(echo "$mars_result" | grep -m1 '^PRINCIPLE:' || true)"
    if [[ -n "$principle_line" ]]; then
        mkdir -p "$principles_dir"
        echo "[${today}] ${principle_line}" >> "$principles_file"
        $SILENT || log "Principle kaydedildi: $principles_file"
    fi

    $SILENT || log "Reflexion + MARS tamamlandi ($safe_caller)."
    return 0
}

RESULT=$(_run_with_timeout "$TIMEOUT" "${CMD[@]}" 2>/dev/null) || {
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 142 || $EXIT_CODE -eq 124 ]]; then
        err "Zaman asimi (${TIMEOUT}s)"
    else
        err "Claude CLI hata kodu: $EXIT_CODE"
    fi
    # Log failure
    echo "{\"timestamp\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"status\":\"FAILED\",\"exit_code\":$EXIT_CODE,\"prompt\":\"$(echo "$PROMPT" | head -c200)\"}" > "$LOG_FILE"
    # Cost log (failure)
    COST_LOG="$HOME/clawd/memory/cost-log.jsonl"
    echo "{\"ts\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration\":0,\"cost\":\"0\",\"turns\":\"0\",\"status\":\"FAILED\",\"caller\":\"${ORACLE_CALLER:-manual}\"}" >> "$COST_LOG"
    # Trajectory (failure)
    append_trajectory "$EXIT_CODE" "0" "0"
    # Shadow agent on failure too
    SHADOW_SCRIPT="$SCRIPT_DIR/shadow-agent.sh"
    if [[ -x "$SHADOW_SCRIPT" ]]; then
        SHADOW_CTX="FAILED Task: $(echo "$PROMPT" | head -c200) | Exit: $EXIT_CODE | Model: $MODEL"
        (echo "$SHADOW_CTX" | "$SHADOW_SCRIPT" review --target "${ORACLE_CALLER:-manual}" --trigger "error" >/dev/null 2>&1) &
    fi
    # Circuit breaker record (failure)
    [[ -x "$CB_SCRIPT" ]] && "$CB_SCRIPT" record "$CB_CALLER" failure >/dev/null 2>&1 || true
    # Reflexion trigger (post-failure hook)
    _reflexion_trigger "$EXIT_CODE" || true
    exit $EXIT_CODE
}

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# === OUTPUT ===
echo "$RESULT"

# === EVAL POST-HOOK ===
EVAL_SCORE=""
if [[ "$EVAL_ENABLED" == "true" ]]; then
    EVAL_SCRIPT="$SCRIPT_DIR/eval.sh"
    if [[ -x "$EVAL_SCRIPT" ]]; then
        EVAL_TMP=$(mktemp)
        echo "$RESULT" > "$EVAL_TMP"
        EVAL_SCORE=$("$EVAL_SCRIPT" --score "$EVAL_TMP" 2>/dev/null) || true
        rm -f "$EVAL_TMP"
        $SILENT || [[ -z "$EVAL_SCORE" ]] || log "Eval score: $EVAL_SCORE"
    fi
fi
export BRIDGE_EVAL_SCORE="${EVAL_SCORE:-}"

# === LOG ===
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Extract metadata + save log in single python3 call
    PROMPT_PREVIEW="$(echo "$PROMPT" | head -c200)"
    IFS=$'\t' read -r COST TURNS < <(echo "$RESULT" | python3 - "$TIMESTAMP" "$DURATION" "$LOG_FILE" "$PROMPT_PREVIEW" <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
cost = data.get('total_cost_usd', 0)
turns = data.get('num_turns', 0)
print(f'{cost}\t{turns}')
data['_oracle_meta'] = {
    'timestamp': sys.argv[1],
    'duration_s': int(sys.argv[2]),
    'prompt_preview': sys.argv[4],
    'preset': 'custom'
}
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    ) || { COST="?"; TURNS="?"; }
    $SILENT || log "Tamamlandi: ${DURATION}s | Maliyet: \$${COST} | Turns: $TURNS"
else
    $SILENT || log "Tamamlandi: ${DURATION}s"
    echo "{\"timestamp\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration_s\":$DURATION,\"status\":\"SUCCESS\",\"prompt\":\"$(echo "$PROMPT" | head -c200)\"}" > "$LOG_FILE"
fi

# === COST LOG (append-only JSONL) ===
COST_LOG="$HOME/clawd/memory/cost-log.jsonl"
COST_ENTRY="{\"ts\":\"$TIMESTAMP\",\"model\":\"$MODEL\",\"duration\":$DURATION,\"cost\":\"${COST:-0}\",\"turns\":\"${TURNS:-1}\",\"status\":\"SUCCESS\",\"caller\":\"${ORACLE_CALLER:-manual}\"}"
echo "$COST_ENTRY" >> "$COST_LOG"

# === TRAJECTORY POOL (append entry for self-evolution tracking) ===
append_trajectory "0" "${COST:-0}" "${TURNS:-1}"

# === SHADOW AGENT POST-HOOK (background, non-blocking) ===
SHADOW_SCRIPT="$SCRIPT_DIR/shadow-agent.sh"
if [[ -x "$SHADOW_SCRIPT" ]]; then
    SHADOW_TARGET="${ORACLE_CALLER:-manual}"
    SHADOW_TRIGGER="task_complete"
    SHADOW_CTX="Task: $(echo "$PROMPT" | head -c200) | Model: $MODEL | Priority: $ORACLE_PRIORITY | Eval: ${EVAL_SCORE:-n/a} | Duration: ${DURATION}s"
    (echo "$SHADOW_CTX" | "$SHADOW_SCRIPT" review --target "$SHADOW_TARGET" --trigger "$SHADOW_TRIGGER" >/dev/null 2>&1) &
fi

# === CRITIQUE POST-HOOK (P0/P1 only, background) ===
CRITIQUE_SCRIPT="$SCRIPT_DIR/critique.sh"
if [[ -x "$CRITIQUE_SCRIPT" && ("$ORACLE_PRIORITY" == "P0" || "$ORACLE_PRIORITY" == "P1") ]]; then
    CRITIQUE_AGENT="${ORACLE_CALLER:-manual}"
    CRITIQUE_TMP=$(mktemp)
    echo "$RESULT" > "$CRITIQUE_TMP"
    ("$CRITIQUE_SCRIPT" --output "$CRITIQUE_TMP" --agent "$CRITIQUE_AGENT" >/dev/null 2>&1; rm -f "$CRITIQUE_TMP") &
fi

# === CIRCUIT BREAKER RECORD (success) ===
[[ -x "$CB_SCRIPT" ]] && "$CB_SCRIPT" record "$CB_CALLER" success >/dev/null 2>&1 || true
