# Evolution Upgrade Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring agent-evolution-kit from 41% to 88% implementation rate by fixing critical bugs, implementing 7 missing features, and integrating 7 relay patterns.

**Architecture:** Production-first approach. All changes go to `~/clawd/` first (oracle-* scripts), then sanitize to `~/agent-evolution-kit/` repo. Bash + Python helpers only, no new compiled dependencies.

**Tech Stack:** Bash 5.x, Python 3.x (stdlib only — json, sqlite3, sys, os, re, datetime), SQLite, YAML configs parsed with Python.

---

## Phase 1: Critical Fixes (Foundation)

### Task 1: Fix Trajectory Pool JSON Format Bug

**Files:**
- Modify: `~/clawd/scripts/oracle-bridge.sh:219-234`
- Verify: `~/clawd/memory/trajectory-pool.json`

**Step 1: Read current trajectory append code**

Confirm the bug: bridge Python code (line 220-234) does `pool = json.load(f)` expecting list, but file is dict with `entries` key.

**Step 2: Fix the Python heredoc in oracle-bridge.sh**

Replace lines 219-234 with:

```bash
# === TRAJECTORY POOL APPEND ===
python3 - "$TRAJECTORY_FILE" "$CALLER" "$MODEL" "$DURATION" "$COST" "$TURNS" "$EXIT_CODE" <<'PYEOF'
import json, sys, os
from datetime import datetime

traj_file = sys.argv[1]
caller = sys.argv[2]
model = sys.argv[3]
duration = float(sys.argv[4])
cost = float(sys.argv[5])
turns = int(sys.argv[6])
exit_code = int(sys.argv[7])

result = "success" if exit_code == 0 else "error"

# Read existing pool (handle both dict and list format)
pool_data = {"_schema_version": "1.0", "_max_entries": 100, "entries": []}
if os.path.exists(traj_file):
    try:
        with open(traj_file) as f:
            raw = json.load(f)
        if isinstance(raw, dict):
            pool_data = raw
            if "entries" not in pool_data:
                pool_data["entries"] = []
        elif isinstance(raw, list):
            pool_data["entries"] = raw
    except (json.JSONDecodeError, IOError):
        pass

entries = pool_data["entries"]
entry = {
    "id": f"traj-{len(entries)+1:03d}",
    "timestamp": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "agent": "oracle-bridge",
    "task_type": caller,
    "model": model,
    "duration_seconds": duration,
    "cost_usd": cost,
    "turns": turns,
    "result": result,
    "key_actions": [],
    "lessons": []
}
entries.append(entry)

# Retain last 100 entries
pool_data["entries"] = entries[-100:]

with open(traj_file, "w") as f:
    json.dump(pool_data, f, indent=2)
PYEOF
```

**Step 3: Verify fix**

Run: `bash -n ~/clawd/scripts/oracle-bridge.sh`
Expected: No syntax errors

Run: `python3 -c "import json; d=json.load(open('$HOME/clawd/memory/trajectory-pool.json')); print(type(d), len(d.get('entries',[])))"`
Expected: `<class 'dict'> 1`

**Step 4: Test with a real bridge call**

Run: `bash ~/clawd/scripts/oracle-bridge.sh --quick --text --silent "Say hello in one word"`

Then verify: `python3 -c "import json; d=json.load(open('$HOME/clawd/memory/trajectory-pool.json')); print(len(d['entries']), d['entries'][-1]['result'])"`
Expected: `2 success`

**Step 5: Commit**

```bash
cd ~/clawd && git add scripts/oracle-bridge.sh && git commit -m "fix(bridge): Fix trajectory pool JSON format — support dict+list, derive result from exit code"
```

---

### Task 2: Circuit Breaker State Machine

**Files:**
- Create: `~/clawd/scripts/oracle-circuit-breaker.sh`
- Create: `~/clawd/memory/circuit-breaker-state.json` (auto-created by script)

**Step 1: Create the circuit breaker script**

```bash
#!/usr/bin/env bash
# oracle-circuit-breaker.sh — Per-agent/tool circuit breaker
# States: CLOSED → OPEN (N failures) → HALF-OPEN (after cooldown) → CLOSED (probe ok)
#
# Usage:
#   oracle-circuit-breaker.sh check <name>        Check if allowed (exit 0=ok, 1=blocked)
#   oracle-circuit-breaker.sh record <name> <result>  Record success/failure
#   oracle-circuit-breaker.sh trip <name>          Force OPEN
#   oracle-circuit-breaker.sh reset <name>         Force CLOSED
#   oracle-circuit-breaker.sh status               Show all breakers

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
STATE_FILE="$AEK_HOME/memory/circuit-breaker-state.json"
EVOLUTION_LOG="$AEK_HOME/memory/evolution-log.md"

DEFAULT_THRESHOLD=3
DEFAULT_COOLDOWN=300
DEFAULT_PROBE_TIMEOUT=60

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ensure_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"breakers":{}}' > "$STATE_FILE"
    fi
}

# All state operations via single Python helper
cb_operation() {
    local op="$1"
    shift
    ensure_state
    python3 - "$STATE_FILE" "$op" "$@" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

state_file = sys.argv[1]
op = sys.argv[2]
args = sys.argv[3:]

DEFAULT_THRESHOLD = 3
DEFAULT_COOLDOWN = 300

with open(state_file) as f:
    data = json.load(f)

breakers = data.get("breakers", {})

def get_breaker(name):
    if name not in breakers:
        breakers[name] = {
            "state": "CLOSED",
            "failure_count": 0,
            "consecutive_failures": 0,
            "last_failure": None,
            "last_state_change": datetime.now(timezone.utc).isoformat(),
            "config": {
                "threshold": DEFAULT_THRESHOLD,
                "cooldown_seconds": DEFAULT_COOLDOWN
            }
        }
    return breakers[name]

def save():
    data["breakers"] = breakers
    with open(state_file, "w") as f:
        json.dump(data, f, indent=2)

now = datetime.now(timezone.utc)

if op == "check":
    name = args[0]
    b = get_breaker(name)
    if b["state"] == "CLOSED":
        print("CLOSED")
        sys.exit(0)
    elif b["state"] == "OPEN":
        # Check if cooldown expired → transition to HALF-OPEN
        cooldown = b["config"]["cooldown_seconds"]
        changed = datetime.fromisoformat(b["last_state_change"])
        elapsed = (now - changed).total_seconds()
        if elapsed >= cooldown:
            b["state"] = "HALF-OPEN"
            b["last_state_change"] = now.isoformat()
            save()
            print("HALF-OPEN")
            sys.exit(0)  # Allow probe
        else:
            remaining = int(cooldown - elapsed)
            print(f"OPEN ({remaining}s remaining)")
            sys.exit(1)
    elif b["state"] == "HALF-OPEN":
        print("HALF-OPEN")
        sys.exit(0)  # Allow probe

elif op == "record":
    name, result = args[0], args[1]
    b = get_breaker(name)
    if result == "success":
        b["consecutive_failures"] = 0
        if b["state"] == "HALF-OPEN":
            b["state"] = "CLOSED"
            b["failure_count"] = 0
            b["last_state_change"] = now.isoformat()
            print(f"HALF-OPEN -> CLOSED (probe succeeded)")
        else:
            print(f"CLOSED (success recorded)")
    else:  # failure
        b["failure_count"] += 1
        b["consecutive_failures"] += 1
        b["last_failure"] = now.isoformat()
        threshold = b["config"]["threshold"]
        if b["state"] == "HALF-OPEN":
            b["state"] = "OPEN"
            b["last_state_change"] = now.isoformat()
            print(f"HALF-OPEN -> OPEN (probe failed)")
        elif b["consecutive_failures"] >= threshold:
            b["state"] = "OPEN"
            b["last_state_change"] = now.isoformat()
            print(f"CLOSED -> OPEN ({b['consecutive_failures']} consecutive failures)")
        else:
            print(f"CLOSED (failure {b['consecutive_failures']}/{threshold})")
    save()

elif op == "trip":
    name = args[0]
    b = get_breaker(name)
    b["state"] = "OPEN"
    b["last_state_change"] = now.isoformat()
    save()
    print(f"TRIPPED: {name} -> OPEN")

elif op == "reset":
    name = args[0]
    b = get_breaker(name)
    b["state"] = "CLOSED"
    b["failure_count"] = 0
    b["consecutive_failures"] = 0
    b["last_state_change"] = now.isoformat()
    save()
    print(f"RESET: {name} -> CLOSED")

elif op == "status":
    if not breakers:
        print("No breakers registered")
    else:
        for name, b in sorted(breakers.items()):
            state = b["state"]
            fails = b["consecutive_failures"]
            total = b["failure_count"]
            print(f"  {name}: {state} (consecutive:{fails} total:{total})")

PYEOF
}

CMD="${1:-status}"
shift || true

case "$CMD" in
    check)   cb_operation check "$@" ;;
    record)  cb_operation record "$@" ;;
    trip)    cb_operation trip "$@" ;;
    reset)   cb_operation reset "$@" ;;
    status)  cb_operation status ;;
    --help|-h)
        echo "Usage: oracle-circuit-breaker.sh <check|record|trip|reset|status> [name] [result]"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        exit 1 ;;
esac
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x ~/clawd/scripts/oracle-circuit-breaker.sh && bash -n ~/clawd/scripts/oracle-circuit-breaker.sh`

**Step 3: Test circuit breaker operations**

```bash
# Test CLOSED state
bash ~/clawd/scripts/oracle-circuit-breaker.sh check test-agent
# Expected: "CLOSED" exit 0

# Record 3 failures → should trip to OPEN
bash ~/clawd/scripts/oracle-circuit-breaker.sh record test-agent failure
bash ~/clawd/scripts/oracle-circuit-breaker.sh record test-agent failure
bash ~/clawd/scripts/oracle-circuit-breaker.sh record test-agent failure
# Expected last: "CLOSED -> OPEN (3 consecutive failures)"

# Check → should be blocked
bash ~/clawd/scripts/oracle-circuit-breaker.sh check test-agent
# Expected: "OPEN (Ns remaining)" exit 1

# Reset for cleanup
bash ~/clawd/scripts/oracle-circuit-breaker.sh reset test-agent

# Dashboard
bash ~/clawd/scripts/oracle-circuit-breaker.sh status
```

**Step 4: Integrate into bridge**

Add circuit breaker check to `oracle-bridge.sh` BEFORE the execution block (before line 152). Add result recording AFTER execution.

Insert before line 152:
```bash
# === Circuit Breaker Check ===
CB_SCRIPT="$SCRIPTS_DIR/oracle-circuit-breaker.sh"
if [[ -x "$CB_SCRIPT" ]]; then
    CB_STATUS=$(bash "$CB_SCRIPT" check "$CALLER" 2>/dev/null) || {
        err "Circuit breaker OPEN for $CALLER: $CB_STATUS"
        exit 2
    }
fi
```

Insert after trajectory append (after line 234, at end of script):
```bash
# === Circuit Breaker Record ===
if [[ -x "$CB_SCRIPT" ]]; then
    if [[ $EXIT_CODE -eq 0 ]]; then
        bash "$CB_SCRIPT" record "$CALLER" success >/dev/null 2>&1 || true
    else
        bash "$CB_SCRIPT" record "$CALLER" failure >/dev/null 2>&1 || true
    fi
fi
```

**Step 5: Commit**

```bash
cd ~/clawd && git add scripts/oracle-circuit-breaker.sh scripts/oracle-bridge.sh && git commit -m "feat(circuit-breaker): Implement CLOSED/OPEN/HALF-OPEN state machine with bridge integration"
```

---

### Task 3: Reflexion Trigger

**Files:**
- Modify: `~/clawd/scripts/oracle-bridge.sh` (add post-execution reflexion hook)
- Verify: `~/clawd/memory/reflections/` directories exist

**Step 1: Add reflexion trigger to bridge**

Add at the end of `oracle-bridge.sh`, after the circuit breaker record block:

```bash
# === Reflexion Trigger ===
if [[ $EXIT_CODE -ne 0 && -x "$BRIDGE_SELF" ]]; then
    REFLECT_DIR="$HOME/clawd/memory/reflections"
    AGENT_DIR="$REFLECT_DIR/${CALLER}"
    mkdir -p "$AGENT_DIR"

    # Check cooldown — skip if same agent reflected in last hour
    LAST_REFLECT=$(find "$AGENT_DIR" -name "*.md" -mmin -60 2>/dev/null | head -1)
    if [[ -z "$LAST_REFLECT" ]]; then
        log "Triggering reflexion for failed task: $CALLER"
        REFLECT_PROMPT="A task just failed. Analyze this failure concisely.

Agent: $CALLER
Task: $TASK_PROMPT_SHORT
Exit code: $EXIT_CODE
Error output (last 500 chars): ${RESULT:(-500)}

Respond in this exact format:
## What happened
[2-3 sentences]

## Root cause
[1-2 sentences]

## Lesson for future
[1 actionable sentence]"

        REFLECTION=$(env -u CLAUDECODE claude -p --model haiku --max-tokens 300 "$REFLECT_PROMPT" 2>/dev/null) || true

        if [[ -n "$REFLECTION" ]]; then
            SAFE_CALLER=$(echo "$CALLER" | sed 's/[^a-zA-Z0-9_-]/-/g' | head -c30)
            REFLECT_FILE="$AGENT_DIR/$(date +%Y-%m-%d)-${SAFE_CALLER}.md"
            cat > "$REFLECT_FILE" <<REFLEOF
# Reflexion — $CALLER — $(date +%Y-%m-%d %H:%M)

$REFLECTION

---
*Auto-generated by reflexion trigger. Exit code: $EXIT_CODE*
REFLEOF
            log "Reflexion saved: $REFLECT_FILE"
        fi
    else
        log "Reflexion skipped (cooldown): $LAST_REFLECT"
    fi
fi
```

Note: `TASK_PROMPT_SHORT` needs to be captured earlier in the script. Add this near line 150 (before execution):
```bash
TASK_PROMPT_SHORT="${@: -1}"
TASK_PROMPT_SHORT="${TASK_PROMPT_SHORT:0:200}"
```

And `BRIDGE_SELF` at the top config section:
```bash
BRIDGE_SELF="$0"
```

**Step 2: Verify syntax**

Run: `bash -n ~/clawd/scripts/oracle-bridge.sh`

**Step 3: Test reflexion trigger**

Force a failure: `bash ~/clawd/scripts/oracle-bridge.sh --quick --text --silent "INVALID_PROMPT_THAT_WILL_FAIL" --max-turns 0`

Check: `ls ~/clawd/memory/reflections/*/`
Expected: A new .md file with reflexion content

**Step 4: Commit**

```bash
cd ~/clawd && git add scripts/oracle-bridge.sh && git commit -m "feat(reflexion): Add auto-reflexion trigger on bridge failure with 1hr cooldown"
```

---

## Phase 2: Missing Feature Implementation

### Task 4: Hybrid Evaluation Script

**Files:**
- Create: `~/clawd/scripts/oracle-eval.sh`

**Step 1: Create the evaluation script**

```bash
#!/usr/bin/env bash
# oracle-eval.sh — Hybrid heuristic + LLM evaluation
#
# Usage:
#   oracle-eval.sh --layer1 <file>         Heuristic check only
#   oracle-eval.sh --full <file>            Layer 1 + conditional Layer 2
#   oracle-eval.sh --score <file>           Just output score (0-100)

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
BRIDGE="$AEK_HOME/scripts/oracle-bridge.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[eval]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[eval]${NC} $1" >&2; }
err() { echo -e "${RED}[eval]${NC} $1" >&2; }

MODE="full"
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --layer1) MODE="layer1"; shift ;;
        --full)   MODE="full"; shift ;;
        --score)  MODE="score"; shift ;;
        --help|-h)
            echo "Usage: oracle-eval.sh [--layer1|--full|--score] <file>"
            exit 0 ;;
        *) INPUT_FILE="$1"; shift ;;
    esac
done

[[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]] && { err "Input file required"; exit 1; }

# === Layer 1: Heuristic (zero cost) ===
LAYER1_RESULT=$(python3 - "$INPUT_FILE" <<'PYEOF'
import sys, re, json
from collections import Counter

with open(sys.argv[1]) as f:
    content = f.read()

checks = {}
score = 100
deductions = []

# 1. Empty output
if len(content.strip()) < 10:
    checks["empty_output"] = "FAIL"
    deductions.append(("empty_output", 25))
else:
    checks["empty_output"] = "PASS"

# 2. Repetitive content (3+ identical sentences)
sentences = [s.strip() for s in re.split(r'[.!?]+', content) if len(s.strip()) > 10]
if sentences:
    counts = Counter(sentences)
    max_repeat = max(counts.values())
    if max_repeat >= 3:
        checks["repetitive"] = "FAIL"
        deductions.append(("repetitive", 15))
    else:
        checks["repetitive"] = "PASS"
else:
    checks["repetitive"] = "PASS"

# 3. Unresolved error patterns
error_patterns = [r"Error:", r"Exception:", r"FAILED", r"Traceback", r"panic:", r"FATAL"]
error_count = sum(1 for p in error_patterns if re.search(p, content))
if error_count >= 2:
    checks["unresolved_errors"] = "FAIL"
    deductions.append(("unresolved_errors", 15))
else:
    checks["unresolved_errors"] = "PASS"

# 4. Length — too short or too long
word_count = len(content.split())
if word_count < 5:
    checks["length"] = "FAIL"
    deductions.append(("too_short", 12))
elif word_count > 10000:
    checks["length"] = "FAIL"
    deductions.append(("too_long", 8))
else:
    checks["length"] = "PASS"

# 5. Hallucination indicators
hallucination_patterns = [
    r"I don't have access",
    r"As an AI",
    r"I cannot browse",
    r"my training data",
    r"I'm unable to"
]
hall_count = sum(1 for p in hallucination_patterns if re.search(p, content, re.IGNORECASE))
if hall_count >= 1:
    checks["hallucination"] = "FAIL"
    deductions.append(("hallucination", 12))
else:
    checks["hallucination"] = "PASS"

# 6. Encoding corruption
if '\x00' in content or re.search(r'[\x80-\xff]{4,}', content):
    checks["encoding"] = "FAIL"
    deductions.append(("encoding", 12))
else:
    checks["encoding"] = "PASS"

# Calculate score
for name, points in deductions:
    score -= points
score = max(0, min(100, score))

# Determine verdict
if score >= 80:
    verdict = "ACCEPT"
elif score >= 40:
    verdict = "GRAY_ZONE"
else:
    verdict = "REJECT"

result = {
    "layer": 1,
    "score": score,
    "verdict": verdict,
    "checks": checks,
    "deductions": deductions
}
print(json.dumps(result))
PYEOF
)

L1_SCORE=$(echo "$LAYER1_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['score'])")
L1_VERDICT=$(echo "$LAYER1_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])")

if [[ "$MODE" == "score" ]]; then
    echo "$L1_SCORE"
    exit 0
fi

log "Layer 1: score=$L1_SCORE verdict=$L1_VERDICT"

if [[ "$MODE" == "layer1" || "$L1_VERDICT" == "ACCEPT" || "$L1_VERDICT" == "REJECT" ]]; then
    echo "$LAYER1_RESULT"
    exit 0
fi

# === Layer 2: LLM evaluation (only for GRAY_ZONE) ===
log "Layer 1 gray zone ($L1_SCORE) — invoking Layer 2 LLM evaluation"

CONTENT_PREVIEW=$(head -c 2000 "$INPUT_FILE")

L2_PROMPT="Rate this agent output on three dimensions (0-10 each):
1. RELEVANCE — Does it address the task?
2. COMPLETENESS — Does it cover all aspects?
3. ACCURACY — Is the information correct?

Output ONLY a JSON object: {\"relevance\": N, \"completeness\": N, \"accuracy\": N}

Agent output:
$CONTENT_PREVIEW"

L2_RAW=$(bash "$BRIDGE" --quick --text --silent "$L2_PROMPT" 2>/dev/null) || {
    warn "Layer 2 LLM call failed — accepting with Layer 1 score"
    echo "$LAYER1_RESULT"
    exit 0
}

# Parse L2 scores
FINAL_RESULT=$(python3 - "$L2_RAW" "$L1_SCORE" <<'PYEOF'
import sys, json, re

raw = sys.argv[1]
l1_score = int(sys.argv[2])

# Extract JSON from LLM response
match = re.search(r'\{[^}]+\}', raw)
if not match:
    print(json.dumps({"layer": 2, "score": l1_score, "verdict": "ACCEPT", "note": "L2 parse failed, using L1"}))
    sys.exit()

try:
    scores = json.loads(match.group())
    r = scores.get("relevance", 5)
    c = scores.get("completeness", 5)
    a = scores.get("accuracy", 5)
    l2_score = int((r * 0.4 + c * 0.3 + a * 0.3) * 10)

    combined = int(l1_score * 0.4 + l2_score * 0.6)

    if combined >= 70:
        verdict = "ACCEPT"
    elif combined >= 40:
        verdict = "ACCEPT_FLAGGED"
    else:
        verdict = "REJECT"

    print(json.dumps({
        "layer": 2,
        "l1_score": l1_score,
        "l2_score": l2_score,
        "combined_score": combined,
        "verdict": verdict,
        "l2_detail": {"relevance": r, "completeness": c, "accuracy": a}
    }))
except:
    print(json.dumps({"layer": 2, "score": l1_score, "verdict": "ACCEPT", "note": "L2 parse failed"}))
PYEOF
)

log "Layer 2: $(echo "$FINAL_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'combined={d.get(\"combined_score\",\"?\")} verdict={d[\"verdict\"]}')")"
echo "$FINAL_RESULT"
```

**Step 2: Make executable, verify syntax**

Run: `chmod +x ~/clawd/scripts/oracle-eval.sh && bash -n ~/clawd/scripts/oracle-eval.sh`

**Step 3: Test with sample content**

```bash
echo "This is a well-formed response about TypeScript best practices. Use strict mode, prefer interfaces over types for object shapes, and always handle errors explicitly." > /tmp/test-eval-good.txt
bash ~/clawd/scripts/oracle-eval.sh --full /tmp/test-eval-good.txt

echo "" > /tmp/test-eval-bad.txt
bash ~/clawd/scripts/oracle-eval.sh --layer1 /tmp/test-eval-bad.txt
```

**Step 4: Commit**

```bash
cd ~/clawd && git add scripts/oracle-eval.sh && git commit -m "feat(eval): Add hybrid heuristic + LLM evaluation with Layer 1/2 pipeline"
```

---

### Task 5: Maker-Checker Loop

**Files:**
- Create: `~/clawd/scripts/oracle-maker-checker.sh`
- Create: `~/clawd/config/maker-checker-pairs.yaml`

**Step 1: Create maker-checker pairs config**

```yaml
# maker-checker-pairs.yaml — Agent pairing for dual verification
pairs:
  - maker: writer
    checker: analyst
    domains: [blog, documentation, report, content]
    threshold: 7
  - maker: scout
    checker: guardian
    domains: [code-review, api-design, security-audit]
    threshold: 8
  - maker: cikcik
    checker: writer
    domains: [social-media, tweet, thread]
    threshold: 7
  - maker: soros
    checker: guardian
    domains: [finance, investment, risk-analysis]
    threshold: 8
  - maker: "*"
    checker: oracle
    domains: ["*"]
    threshold: 7
```

**Step 2: Create maker-checker script**

```bash
#!/usr/bin/env bash
# oracle-maker-checker.sh — Dual-agent verification loop
#
# Usage:
#   oracle-maker-checker.sh --maker <agent> --checker <agent> --task "desc" --input <file>
#   oracle-maker-checker.sh --auto --task "desc" --input <file>   (auto-select checker from config)

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
BRIDGE="$AEK_HOME/scripts/oracle-bridge.sh"
CONFIG="$AEK_HOME/config/maker-checker-pairs.yaml"
MAX_ITERATIONS=3

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[mc]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[mc]${NC} $1" >&2; }

MAKER="" CHECKER="" TASK="" INPUT_FILE="" AUTO=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --maker)   MAKER="$2"; shift 2 ;;
        --checker) CHECKER="$2"; shift 2 ;;
        --task)    TASK="$2"; shift 2 ;;
        --input)   INPUT_FILE="$2"; shift 2 ;;
        --auto)    AUTO=true; shift ;;
        --help|-h)
            echo "Usage: oracle-maker-checker.sh --maker <agent> --checker <agent> --task 'desc' --input <file>"
            exit 0 ;;
        *) shift ;;
    esac
done

[[ -z "$TASK" ]] && { echo "Error: --task required" >&2; exit 1; }
[[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]] && { echo "Error: --input <file> required" >&2; exit 1; }

# Auto-select checker from config
if [[ "$AUTO" == "true" && -z "$CHECKER" && -f "$CONFIG" ]]; then
    CHECKER=$(python3 - "$CONFIG" "$MAKER" "$TASK" <<'PYEOF'
import sys, re

config_file, maker, task = sys.argv[1], sys.argv[2], sys.argv[3]
task_lower = task.lower()

# Simple YAML parsing (no pyyaml dependency)
with open(config_file) as f:
    content = f.read()

# Extract pairs
pairs = []
current = {}
for line in content.split('\n'):
    line = line.strip()
    if line.startswith('- maker:'):
        if current:
            pairs.append(current)
        current = {'maker': line.split(':', 1)[1].strip()}
    elif line.startswith('checker:'):
        current['checker'] = line.split(':', 1)[1].strip()
    elif line.startswith('domains:'):
        domains_str = line.split(':', 1)[1].strip()
        current['domains'] = [d.strip().strip('[]') for d in domains_str.split(',')]
    elif line.startswith('threshold:'):
        current['threshold'] = int(line.split(':', 1)[1].strip())
if current:
    pairs.append(current)

# Match
for p in pairs:
    if p['maker'] in (maker, '*'):
        if '*' in p.get('domains', []):
            print(p['checker'])
            break
        for d in p.get('domains', []):
            if d in task_lower:
                print(p['checker'])
                break
        else:
            continue
        break
else:
    print('oracle')
PYEOF
)
    log "Auto-selected checker: $CHECKER"
fi

[[ -z "$MAKER" ]] && MAKER="unknown"
[[ -z "$CHECKER" ]] && CHECKER="oracle"

log "Maker-Checker Loop: maker=$MAKER checker=$CHECKER max_iterations=$MAX_ITERATIONS"

CURRENT_INPUT="$INPUT_FILE"
ITERATION=0

while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ITERATION=$((ITERATION + 1))
    log "Iteration $ITERATION/$MAX_ITERATIONS"

    CONTENT=$(cat "$CURRENT_INPUT")

    CHECKER_PROMPT="You are a checker reviewing work by $MAKER.
Task: $TASK

Review this output and respond with EXACTLY one of:
- APPROVE: [brief reason] — if quality is sufficient
- ISSUE: [specific feedback for improvement] — if fixable issues exist
- REJECT: [reason] — if fundamentally flawed

Output to review:
${CONTENT:0:3000}"

    CHECKER_RESPONSE=$(bash "$BRIDGE" --quick --text --silent "$CHECKER_PROMPT" 2>/dev/null) || {
        warn "Checker call failed — accepting maker output"
        break
    }

    log "Checker response: $(echo "$CHECKER_RESPONSE" | head -1)"

    if echo "$CHECKER_RESPONSE" | grep -qi "^APPROVE"; then
        log "APPROVED at iteration $ITERATION"
        echo "$CONTENT"

        # Record to trajectory
        python3 - "$AEK_HOME/memory/trajectory-pool.json" "$MAKER" "$CHECKER" "$ITERATION" "APPROVED" <<'PYEOF'
import json, sys, os
from datetime import datetime
traj_file, maker, checker, iterations, result = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    with open(traj_file) as f:
        data = json.load(f)
    entries = data.get("entries", []) if isinstance(data, dict) else data
except:
    entries = []
    data = {"_schema_version": "1.0", "entries": entries}
# Just update last entry with checker info if exists
if entries:
    entries[-1]["checker_agent"] = checker
    entries[-1]["checker_result"] = result
    entries[-1]["checker_iterations"] = int(iterations)
if isinstance(data, dict):
    data["entries"] = entries
    with open(traj_file, "w") as f:
        json.dump(data, f, indent=2)
PYEOF
        exit 0
    fi

    if echo "$CHECKER_RESPONSE" | grep -qi "^REJECT"; then
        warn "REJECTED at iteration $ITERATION"
        echo "$CHECKER_RESPONSE" >&2
        exit 1
    fi

    # ISSUE — send feedback to maker for revision
    if [[ $ITERATION -lt $MAX_ITERATIONS ]]; then
        FEEDBACK=$(echo "$CHECKER_RESPONSE" | sed 's/^ISSUE://i' | head -20)

        REVISION_PROMPT="Your previous output was reviewed and needs improvement.
Task: $TASK
Feedback: $FEEDBACK

Original output:
${CONTENT:0:2000}

Revise your output addressing the feedback."

        REVISED=$(bash "$BRIDGE" --analyze --text --silent "$REVISION_PROMPT" 2>/dev/null) || {
            warn "Revision call failed — returning current output"
            echo "$CONTENT"
            exit 0
        }

        TEMP_FILE=$(mktemp)
        echo "$REVISED" > "$TEMP_FILE"
        CURRENT_INPUT="$TEMP_FILE"
        log "Revised output received, re-submitting to checker"
    fi
done

warn "Max iterations reached ($MAX_ITERATIONS) — returning last version"
cat "$CURRENT_INPUT"
exit 0
```

**Step 3: Make executable, verify syntax, test**

```bash
chmod +x ~/clawd/scripts/oracle-maker-checker.sh
bash -n ~/clawd/scripts/oracle-maker-checker.sh
```

**Step 4: Commit**

```bash
cd ~/clawd && git add scripts/oracle-maker-checker.sh config/maker-checker-pairs.yaml && git commit -m "feat(maker-checker): Implement dual-agent verification loop with auto-checker selection"
```

---

### Task 6: MARS Metacognitive Extraction

**Files:**
- Modify: `~/clawd/scripts/oracle-bridge.sh` (extend reflexion trigger)

**Step 1: Add MARS extraction after reflexion**

In `oracle-bridge.sh`, after the reflexion file is saved (inside the `if [[ -n "$REFLECTION" ]]` block), add:

```bash
            # === MARS Metacognitive Extraction ===
            MARS_PROMPT="From this reflection, extract exactly two things:

PRINCIPLE: A normative rule in the format 'Always X when Y because Z' or 'Never X when Y because Z'

PROCEDURE: The steps that were taken, in numbered format (Step 1: ..., Step 2: ...)

Reflection:
$REFLECTION

Respond ONLY with:
PRINCIPLE: [your principle]
PROCEDURE:
1. [step]
2. [step]"

            MARS_RESULT=$(env -u CLAUDECODE claude -p --model haiku --max-tokens 200 "$MARS_PROMPT" 2>/dev/null) || true

            if [[ -n "$MARS_RESULT" ]]; then
                # Extract principle → append to principles file
                PRINCIPLE=$(echo "$MARS_RESULT" | grep -i "^PRINCIPLE:" | sed 's/^PRINCIPLE://i' | xargs)
                if [[ -n "$PRINCIPLE" ]]; then
                    PRINCIPLES_FILE="$HOME/clawd/memory/principles/${SAFE_CALLER}.md"
                    mkdir -p "$(dirname "$PRINCIPLES_FILE")"
                    echo "- $(date +%Y-%m-%d): $PRINCIPLE" >> "$PRINCIPLES_FILE"
                    log "MARS principle extracted → $PRINCIPLES_FILE"
                fi

                # Extract procedure → save for replay
                PROCEDURE=$(echo "$MARS_RESULT" | sed -n '/^PROCEDURE:/,$ p' | tail -n +2)
                if [[ -n "$PROCEDURE" ]]; then
                    echo "$PROCEDURE" >> "$REFLECT_FILE"
                    log "MARS procedure appended to reflexion"
                fi
            fi
```

**Step 2: Verify syntax**

Run: `bash -n ~/clawd/scripts/oracle-bridge.sh`

**Step 3: Commit**

```bash
cd ~/clawd && git add scripts/oracle-bridge.sh && git commit -m "feat(mars): Add metacognitive principle+procedure extraction post-reflexion"
```

---

### Task 7: AgentRR Replay Script

**Files:**
- Create: `~/clawd/scripts/oracle-replay.sh`

**Step 1: Create replay script**

```bash
#!/usr/bin/env bash
# oracle-replay.sh — Replay past trajectories as in-context examples
#
# Usage:
#   oracle-replay.sh --task-type "code-review"    Find matching trajectories
#   oracle-replay.sh --task-type "code-review" --inject   Output formatted for prompt injection

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
MAX_EXAMPLES=3
MAX_TOKENS_PER=500
INJECT=false
TASK_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --task-type) TASK_TYPE="$2"; shift 2 ;;
        --max)       MAX_EXAMPLES="$2"; shift 2 ;;
        --inject)    INJECT=true; shift ;;
        --help|-h)
            echo "Usage: oracle-replay.sh --task-type <type> [--max N] [--inject]"
            exit 0 ;;
        *) shift ;;
    esac
done

[[ -z "$TASK_TYPE" ]] && { echo "Error: --task-type required" >&2; exit 1; }

python3 - "$TRAJECTORY" "$TASK_TYPE" "$MAX_EXAMPLES" "$MAX_TOKENS_PER" "$INJECT" <<'PYEOF'
import json, sys, os

traj_file = sys.argv[1]
task_type = sys.argv[2].lower()
max_examples = int(sys.argv[3])
max_chars = int(sys.argv[4]) * 4  # ~4 chars per token
inject_mode = sys.argv[5] == "true"

if not os.path.exists(traj_file):
    if not inject_mode:
        print("No trajectory pool found")
    sys.exit(0)

with open(traj_file) as f:
    raw = json.load(f)

entries = raw.get("entries", raw) if isinstance(raw, dict) else raw

# Filter by task type (case-insensitive partial match)
matching = [e for e in entries if task_type in e.get("task_type", "").lower()]

if not matching:
    if not inject_mode:
        print(f"No trajectories found for task type: {task_type}")
    sys.exit(0)

# Sort: successes first, then by recency
successes = sorted([e for e in matching if e.get("result") == "success"],
                   key=lambda x: x.get("timestamp", ""), reverse=True)
failures = sorted([e for e in matching if e.get("result") != "success"],
                  key=lambda x: x.get("timestamp", ""), reverse=True)

# Select: prefer successes, include at least 1 failure if available
selected = []
selected.extend(successes[:max_examples - 1] if failures else successes[:max_examples])
if failures and len(selected) < max_examples:
    selected.append(failures[0])

if inject_mode:
    print("## Past Experience (auto-injected)")
    print()
    for i, entry in enumerate(selected, 1):
        result = entry.get("result", "unknown").upper()
        lessons = entry.get("lessons", [])
        actions = entry.get("key_actions", [])
        print(f"### Example {i} ({result})")
        print(f"- Task: {entry.get('task_type', '?')}")
        print(f"- Duration: {entry.get('duration_seconds', '?')}s")
        if actions:
            print(f"- Actions: {', '.join(str(a) for a in actions[:5])}")
        if lessons:
            print(f"- Lessons: {'; '.join(str(l) for l in lessons[:3])}")
        print()
else:
    print(f"Found {len(matching)} trajectories for '{task_type}', selected {len(selected)}:")
    for entry in selected:
        print(f"  [{entry.get('result','?').upper()}] {entry.get('id','?')} — {entry.get('task_type','?')} ({entry.get('duration_seconds','?')}s)")
PYEOF
```

**Step 2: Make executable, verify, test**

```bash
chmod +x ~/clawd/scripts/oracle-replay.sh
bash -n ~/clawd/scripts/oracle-replay.sh
bash ~/clawd/scripts/oracle-replay.sh --task-type "self-evolution"
```

**Step 3: Add --replay flag to bridge**

In `oracle-bridge.sh`, before the main execution block, add replay injection:

```bash
# === Replay Injection ===
REPLAY_SCRIPT="$SCRIPTS_DIR/oracle-replay.sh"
if [[ "${REPLAY:-false}" == "true" && -x "$REPLAY_SCRIPT" ]]; then
    REPLAY_CONTEXT=$(bash "$REPLAY_SCRIPT" --task-type "$CALLER" --inject 2>/dev/null) || true
    if [[ -n "$REPLAY_CONTEXT" ]]; then
        # Prepend replay context to the prompt
        PROMPT_WITH_REPLAY="$REPLAY_CONTEXT

---
$ORIGINAL_PROMPT"
        log "Replay: injected $(echo "$REPLAY_CONTEXT" | wc -l | tr -d ' ') lines of past experience"
    fi
fi
```

Add `--replay` flag parsing in the argument section.

**Step 4: Commit**

```bash
cd ~/clawd && git add scripts/oracle-replay.sh scripts/oracle-bridge.sh && git commit -m "feat(replay): Add trajectory replay with in-context example injection"
```

---

### Task 8: 5-Level Autonomy Enforcement

**Files:**
- Create: `~/clawd/config/autonomy-levels.yaml`
- Modify: `~/clawd/scripts/oracle-governance.sh`

**Step 1: Create autonomy levels config**

```yaml
# autonomy-levels.yaml — Progressive autonomy based on trust score
levels:
  L1_reactive:
    trust_min: 0
    trust_max: 499
    allowed_actions: [read, search, respond_to_human]
    blocked_actions: [write_code, execute_script, delegate, tool_create, prompt_modify]
    description: "Human-initiated only, read-only operations"

  L2_scheduled:
    trust_min: 500
    trust_max: 599
    allowed_actions: [read, search, respond_to_human, execute_cron, run_known_scripts]
    blocked_actions: [write_code, delegate, tool_create, prompt_modify]
    description: "Can run scheduled tasks and known scripts"

  L3_self_monitoring:
    trust_min: 600
    trust_max: 899
    allowed_actions: [read, search, respond_to_human, execute_cron, run_known_scripts, watchdog_restart, circuit_breaker, alert, self_diagnose]
    blocked_actions: [prompt_modify, agent_config_change, tool_create]
    description: "Self-healing, circuit breaker, alerting"

  L4_self_improving:
    trust_min: 900
    trust_max: 999
    allowed_actions: [read, search, respond_to_human, execute_cron, run_known_scripts, watchdog_restart, circuit_breaker, alert, self_diagnose, reflexion, prompt_evolution, trajectory_learning, maker_checker]
    blocked_actions: [tool_synthesis, governance_change]
    description: "Self-improvement with operator approval"

  L5_autonomous:
    trust_min: 1000
    trust_max: 9999
    allowed_actions: [all]
    blocked_actions: [governance_change]
    description: "Full autonomy (future)"

# Dynamic adjustment rules
adjustments:
  promote:
    consecutive_successes: 10
    requires_approval: true
  demote:
    consecutive_failures: 3
    automatic: true
```

**Step 2: Add autonomy check to governance.sh**

Add a new command `cmd_autonomy()` to `oracle-governance.sh` and integrate level checking into `cmd_check()`.

In `cmd_check()`, after trust level retrieval (around line 196), add:

```bash
    # Autonomy level check
    AUTONOMY_LEVEL=$(python3 - "$AEK_HOME/config/autonomy-levels.yaml" "$trust_level" "$action" <<'PYEOF'
import sys, re

config_file, trust, action = sys.argv[1], int(sys.argv[2]), sys.argv[3]

# Simple YAML parsing
levels = {}
current_name = None
current = {}
with open(config_file) as f:
    for line in f:
        line = line.rstrip()
        if re.match(r'  L\d_', line):
            if current_name:
                levels[current_name] = current
            current_name = line.strip().rstrip(':')
            current = {}
        elif 'trust_min:' in line:
            current['trust_min'] = int(line.split(':')[1].strip())
        elif 'trust_max:' in line:
            current['trust_max'] = int(line.split(':')[1].strip())
        elif 'blocked_actions:' in line:
            actions_str = line.split(':',1)[1].strip()
            current['blocked'] = [a.strip().strip('[]') for a in actions_str.split(',')]
if current_name:
    levels[current_name] = current

# Find agent's level
agent_level = "L1_reactive"
for name, cfg in sorted(levels.items()):
    if cfg.get('trust_min', 0) <= trust <= cfg.get('trust_max', 9999):
        agent_level = name

# Check if action is blocked
blocked = levels.get(agent_level, {}).get('blocked', [])
if action in blocked:
    print(f"BLOCKED {agent_level}")
else:
    print(f"ALLOWED {agent_level}")
PYEOF
)

    if echo "$AUTONOMY_LEVEL" | grep -q "^BLOCKED"; then
        local level_name=$(echo "$AUTONOMY_LEVEL" | awk '{print $2}')
        warn "AUTONOMY BLOCKED: $agent ($level_name) cannot perform $action"
        log_audit "$agent" "$action" "DENY" "autonomy_level=$level_name"
        echo "DENY"
        return
    fi
```

**Step 3: Verify syntax**

```bash
bash -n ~/clawd/scripts/oracle-governance.sh
```

**Step 4: Commit**

```bash
cd ~/clawd && git add config/autonomy-levels.yaml scripts/oracle-governance.sh && git commit -m "feat(autonomy): Add 5-level trust-based autonomy enforcement with dynamic adjustment"
```

---

## Phase 3: relay Pattern Integration

### Task 9: Swarm Pattern Catalog + Runner

**Files:**
- Create: `~/clawd/config/swarm-patterns/` (8 YAML files)
- Create: `~/clawd/scripts/oracle-swarm.sh`

**Step 1: Create priority swarm patterns**

Create 8 YAML pattern files in `~/clawd/config/swarm-patterns/`:

`consensus.yaml`:
```yaml
name: consensus
description: "Multiple agents vote on same question, result by majority/supermajority/unanimous"
agents_min: 3
flow: parallel_then_vote
config:
  consensus_type: majority  # majority|supermajority|unanimous|weighted|quorum
  timeout_seconds: 300
  on_no_consensus: escalate_to_orchestrator
  early_termination: true
```

`pipeline.yaml`:
```yaml
name: pipeline
description: "Sequential A→B→C, each step receives previous output"
agents_min: 2
flow: sequential
config:
  pass_output: true
  fail_fast: true
  timeout_per_step: 120
```

`fan-out.yaml`:
```yaml
name: fan-out
description: "Same task sent to N agents in parallel, results merged"
agents_min: 2
flow: parallel_then_merge
config:
  merge_strategy: concatenate  # concatenate|best_score|consensus
  timeout_seconds: 300
```

`reflection.yaml`:
```yaml
name: reflection
description: "Agent output sent back to itself for self-critique and revision"
agents_min: 1
flow: loop
config:
  max_iterations: 2
  stop_on: self_approve
```

`review-loop.yaml`:
```yaml
name: review-loop
description: "Maker produces, checker reviews, loop until approved"
agents_min: 2
flow: maker_checker
config:
  max_iterations: 3
  threshold: 7
```

`red-team.yaml`:
```yaml
name: red-team
description: "One agent produces, another attacks/challenges, third judges"
agents_min: 3
flow: adversarial
config:
  roles: [producer, attacker, judge]
  max_rounds: 2
```

`escalation.yaml`:
```yaml
name: escalation
description: "Start with cheap model, escalate to expensive on failure"
agents_min: 1
flow: cascade
config:
  model_chain: [haiku, sonnet, opus]
  escalate_on: [failure, low_confidence, gray_zone_eval]
```

`circuit-breaker.yaml`:
```yaml
name: circuit-breaker
description: "Wrap execution with circuit breaker, fallback on OPEN"
agents_min: 1
flow: guarded
config:
  threshold: 3
  cooldown_seconds: 300
  fallback: return_cached_or_error
```

**Step 2: Create swarm runner script**

`oracle-swarm.sh` — reads YAML pattern, orchestrates agents via bridge. ~200 lines. Core logic:

```bash
#!/usr/bin/env bash
# oracle-swarm.sh — Multi-agent swarm orchestration
#
# Usage:
#   oracle-swarm.sh --pattern consensus --agents "analyst,researcher,guardian" --task "Evaluate X"
#   oracle-swarm.sh --pattern pipeline --agents "researcher,analyst,writer" --task "Research and write about X"
#   oracle-swarm.sh --pattern escalation --task "Solve X"

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
BRIDGE="$AEK_HOME/scripts/oracle-bridge.sh"
PATTERNS_DIR="$AEK_HOME/config/swarm-patterns"
CONSENSUS_PY="$AEK_HOME/scripts/helpers/consensus.py"

# [argument parsing, pattern loading, agent orchestration via bridge calls]
# Implementation: Python helper reads YAML, dispatches bridge calls based on flow type
```

Full implementation follows the pattern: parse YAML → determine flow type → execute bridge calls accordingly → collect results → apply merge/vote/escalation strategy.

**Step 3: Commit**

```bash
cd ~/clawd && git add config/swarm-patterns/ scripts/oracle-swarm.sh && git commit -m "feat(swarm): Add 8 swarm pattern YAMLs + orchestration runner"
```

---

### Task 10: Consensus Engine (Python Helper)

**Files:**
- Create: `~/clawd/scripts/helpers/consensus.py`

**Step 1: Create consensus helper**

```python
#!/usr/bin/env python3
"""Consensus engine — 5 voting types for multi-agent decisions.

Usage:
    echo '[{"agent":"a","vote":"APPROVE"},...]' | python3 consensus.py --type majority
    python3 consensus.py --type weighted --file votes.json
"""
import json, sys, argparse
from collections import Counter

def majority(votes, threshold=0.5):
    counts = Counter(v["vote"] for v in votes)
    total = len(votes)
    winner, count = counts.most_common(1)[0]
    if count / total > threshold:
        return {"result": winner, "decided": True, "margin": count/total}
    return {"result": None, "decided": False, "margin": count/total}

def supermajority(votes):
    return majority(votes, threshold=0.666)

def unanimous(votes):
    unique = set(v["vote"] for v in votes)
    if len(unique) == 1:
        return {"result": unique.pop(), "decided": True, "margin": 1.0}
    return {"result": None, "decided": False, "margin": 0}

def weighted(votes):
    scores = {}
    for v in votes:
        vote, weight = v["vote"], v.get("weight", 1.0)
        scores[vote] = scores.get(vote, 0) + weight
    winner = max(scores, key=scores.get)
    total_weight = sum(scores.values())
    return {"result": winner, "decided": True, "margin": scores[winner]/total_weight, "scores": scores}

def quorum(votes, min_participants=None):
    if min_participants is None:
        min_participants = max(2, len(votes) // 2)
    if len(votes) < min_participants:
        return {"result": None, "decided": False, "reason": f"Quorum not met ({len(votes)}/{min_participants})"}
    return majority(votes)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--type", required=True, choices=["majority","supermajority","unanimous","weighted","quorum"])
    parser.add_argument("--file", help="JSON file with votes array")
    parser.add_argument("--quorum-min", type=int, default=None)
    args = parser.parse_args()

    if args.file:
        with open(args.file) as f:
            votes = json.load(f)
    else:
        votes = json.load(sys.stdin)

    engines = {
        "majority": lambda v: majority(v),
        "supermajority": lambda v: supermajority(v),
        "unanimous": lambda v: unanimous(v),
        "weighted": lambda v: weighted(v),
        "quorum": lambda v: quorum(v, args.quorum_min),
    }

    result = engines[args.type](votes)
    result["consensus_type"] = args.type
    result["total_votes"] = len(votes)
    result["vote_counts"] = dict(Counter(v["vote"] for v in votes))
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
```

**Step 2: Test**

```bash
echo '[{"agent":"a","vote":"APPROVE"},{"agent":"b","vote":"APPROVE"},{"agent":"c","vote":"REJECT"}]' | python3 ~/clawd/scripts/helpers/consensus.py --type majority
```

Expected: `{"result": "APPROVE", "decided": true, ...}`

**Step 3: Commit**

```bash
cd ~/clawd && mkdir -p scripts/helpers && git add scripts/helpers/consensus.py && git commit -m "feat(consensus): Add 5-type voting engine (majority/supermajority/unanimous/weighted/quorum)"
```

---

### Task 11: Supervisor Restart Policy (Watchdog Upgrade)

**Files:**
- Create: `~/clawd/config/restart-policies.yaml`
- Modify: `~/clawd/scripts/oracle-watchdog.sh` (parameterize restart logic)

**Step 1: Create restart policies config**

```yaml
agents:
  openclaw-gateway:
    max_restarts: 5
    max_consecutive_failures: 3
    cooldown_seconds: 2
    backoff: exponential
    max_backoff_seconds: 60
    stability_reset_seconds: 300
    permanently_dead_action: alert_operator
  default:
    max_restarts: 3
    max_consecutive_failures: 2
    cooldown_seconds: 5
    backoff: linear
    max_backoff_seconds: 30
    stability_reset_seconds: 300
    permanently_dead_action: log_only
```

**Step 2: Add policy loading to watchdog**

In `oracle-watchdog.sh`, after state loading, add policy-aware restart logic. Replace hardcoded `L3_FAIL_THRESHOLD=3` with config-driven values. Add exponential backoff calculation and PermanentlyDead state.

**Step 3: Commit**

```bash
cd ~/clawd && git add config/restart-policies.yaml scripts/oracle-watchdog.sh && git commit -m "feat(supervisor): Add parameterized restart policy with exponential backoff"
```

---

### Task 12: Crash Insights (Agent Health Upgrade)

**Files:**
- Modify: `~/clawd/scripts/oracle-agent-health.sh`

**Step 1: Add crash categorization and health score**

Extend the agent loop to include:
- Crash pattern detection from logs (OOM, Segfault, Timeout, ConfigError, GenericError)
- Health score calculation: `100 - (recent_crashes * 20) - (slow_restart ? 15 : 0) - (consecutive_fails * 10) - (cb_open ? 25 : 0)`
- Persistent crash history in `memory/crash-insights.json`
- Integration with briefing and predict

**Step 2: Commit**

```bash
cd ~/clawd && git add scripts/oracle-agent-health.sh && git commit -m "feat(crash-insights): Add crash categorization and health scoring"
```

---

### Task 13: Priority Queue + Shadow Agent

**Files:**
- Create: `~/clawd/config/priority-rules.yaml`
- Create: `~/clawd/config/shadow-agents.yaml`

**Step 1: Create configs**

`priority-rules.yaml`:
```yaml
levels:
  P0: {name: Critical, keywords: [security, data-loss, urgent-production], never_drop: true}
  P1: {name: High, keywords: [bug, fix, broken, regression], never_drop: true}
  P2: {name: Normal, keywords: [], never_drop: false}
  P3: {name: Low, keywords: [research, improvement, nice-to-have], never_drop: false}
  P4: {name: Background, keywords: [cleanup, optimization, refactor], never_drop: false}
queue:
  max_pending: 30
  drop_p4_at: 20
  drop_p3_at: 30
```

`shadow-agents.yaml`:
```yaml
shadows:
  - observer: guardian
    target: writer
    speak_on: [code_written, security_risk]
    mode: passive
    max_reviews_per_day: 5
  - observer: analyst
    target: scout
    speak_on: [task_complete]
    mode: review
    max_reviews_per_day: 3
```

**Step 2: Commit**

```bash
cd ~/clawd && git add config/priority-rules.yaml config/shadow-agents.yaml && git commit -m "feat(config): Add priority queue rules and shadow agent config"
```

---

## Phase 4: Repo Sync

### Task 14: Sanitize and Push to Public Repo

**Files:**
- All new scripts → `~/agent-evolution-kit/scripts/` (with oracle- prefix removed)
- All new configs → `~/agent-evolution-kit/config/`
- New docs → `~/agent-evolution-kit/docs/`
- Updated README.md

**Step 1: Copy and sanitize all new files**

Run sanitization: replace all Oracle/Hachiko/Mahsum/CikCik/Soros/Tithonos/clawd references with generic names. Remove hardcoded paths. Replace `$HOME/clawd` with `$AEK_HOME`.

**Step 2: Update README.md**

- Add new concepts to Core Concepts section
- Update differentiator table
- Update repo tree

**Step 3: Verify sanitization**

```bash
cd ~/agent-evolution-kit
grep -r "Mahsum\|clawd\|openclaw\|CikCik\|Soros\|Tithonos\|Hachiko\|Oracle" --include="*.sh" --include="*.md" --include="*.yaml" --include="*.py" .
```
Expected: 0 results

**Step 4: Verify all scripts**

```bash
for f in scripts/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done
```

**Step 5: Commit and push**

```bash
cd ~/agent-evolution-kit && git add -A && git commit -m "feat: Phase 1-4 evolution upgrade — 6 new scripts, 7 relay patterns, 14 configs"
git push origin main
```

---

## Execution Summary

| Phase | Tasks | Est. New/Modified Files |
|-------|-------|------------------------|
| Phase 1 | Task 1-3 | 2 modified, 1 new |
| Phase 2 | Task 4-8 | 3 new, 2 modified, 2 configs |
| Phase 3 | Task 9-13 | 3 new, 2 modified, 10+ configs |
| Phase 4 | Task 14 | ~20 files synced to repo |
| **Total** | **14 tasks** | **~35 files** |
