#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# replay.sh — AgentRR Replay: Past trajectory injection for ICL
#
# Usage:
#   replay.sh --task-type "code-review"                  # Summary table
#   replay.sh --task-type "code-review" --inject         # Prompt injection
#   replay.sh --task-type "code-review" --max 5 --inject # Custom max
#
# Reads trajectory-pool.json and selects relevant past
# trajectories for in-context learning. Supports both summary table
# and markdown injection output modes.

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

TRAJ_FILE="$AEK_HOME/memory/trajectory-pool.json"
MAX_EXAMPLES=3
MAX_TOKENS_PER=500
TASK_TYPE=""
INJECT_MODE="false"

usage() {
  cat <<'EOF'
Usage: replay.sh --task-type <type> [--max N] [--inject]

Options:
  --task-type <type>   Filter trajectories by task type (partial, case-insensitive)
  --max <N>            Max examples to return (default: 3)
  --inject             Output markdown formatted for prompt injection
  -h, --help           Show this help
EOF
  exit 0
}

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-type)
      TASK_TYPE="$2"
      shift 2
      ;;
    --max)
      MAX_EXAMPLES="$2"
      shift 2
      ;;
    --inject)
      INJECT_MODE="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$TASK_TYPE" ]]; then
  echo "Error: --task-type is required" >&2
  usage
fi

# --- Early exit if no trajectory file ---
if [[ ! -f "$TRAJ_FILE" ]]; then
  [[ "$INJECT_MODE" == "true" ]] && exit 0
  echo "No trajectory file found at $TRAJ_FILE"
  exit 0
fi

# --- Python heredoc: filter, sort, format ---
MAX_CHARS_PER=$(( MAX_TOKENS_PER * 4 ))

python3 - "$TRAJ_FILE" "$TASK_TYPE" "$MAX_EXAMPLES" "$MAX_CHARS_PER" "$INJECT_MODE" <<'PYEOF'
import json
import sys
from datetime import datetime

traj_file = sys.argv[1]
task_type = sys.argv[2].lower()
max_examples = int(sys.argv[3])
max_chars_per = int(sys.argv[4])
inject_mode = sys.argv[5] == "true"

# 1. Read trajectory pool
try:
    with open(traj_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)

# Handle both dict with "entries" key and flat list
if isinstance(data, dict):
    entries = data.get("entries", [])
elif isinstance(data, list):
    entries = data
else:
    sys.exit(0)

if not entries:
    sys.exit(0)

# 2. Filter by task_type (case-insensitive partial match)
matched = [
    e for e in entries
    if task_type in e.get("task_type", "").lower()
]

if not matched:
    if inject_mode:
        sys.exit(0)
    print(f"No trajectories matching '{task_type}'")
    sys.exit(0)

# 3. Sort: successes first (by recency), then failures (by recency)
def parse_ts(entry):
    ts = entry.get("timestamp", "1970-01-01T00:00:00Z")
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return datetime.min

successes = sorted(
    [e for e in matched if e.get("result", "").upper() == "SUCCESS"],
    key=parse_ts,
    reverse=True,
)
failures = sorted(
    [e for e in matched if e.get("result", "").upper() != "SUCCESS"],
    key=parse_ts,
    reverse=True,
)

# 4. Select top N: prefer successes, include at least 1 failure for contrast
selected = []
if failures and max_examples > 1:
    # Reserve 1 slot for a failure
    success_slots = max_examples - 1
    selected = successes[:success_slots]
    selected.append(failures[0])
    # Fill remaining slots with more successes if available
    remaining = max_examples - len(selected)
    if remaining > 0:
        extra = [s for s in successes[success_slots:]][:remaining]
        selected.extend(extra)
elif failures and max_examples == 1:
    # Only 1 slot — prefer success if available, else failure
    selected = successes[:1] if successes else failures[:1]
else:
    # No failures
    selected = successes[:max_examples]

# Re-sort selected: successes first, then failures, each by recency
selected_succ = [e for e in selected if e.get("result", "").upper() == "SUCCESS"]
selected_fail = [e for e in selected if e.get("result", "").upper() != "SUCCESS"]
selected_succ.sort(key=parse_ts, reverse=True)
selected_fail.sort(key=parse_ts, reverse=True)
selected = selected_succ + selected_fail

# --- Helper: truncate text to max_chars ---
def truncate(text, limit):
    if not text:
        return ""
    s = str(text)
    if len(s) <= limit:
        return s
    return s[:limit - 3] + "..."

def format_list(items, char_budget):
    if not items:
        return "(none)"
    lines = []
    used = 0
    for item in items:
        s = str(item)
        if used + len(s) > char_budget:
            s = s[:max(0, char_budget - used - 3)] + "..."
            lines.append(s)
            break
        lines.append(s)
        used += len(s)
    return ", ".join(lines)

# 5. Output
if inject_mode:
    # --- Markdown injection mode ---
    print("## Past Experience (auto-injected)\n")
    for i, entry in enumerate(selected, 1):
        result = entry.get("result", "UNKNOWN").upper()
        task = truncate(entry.get("task", entry.get("task_type", "unknown")), max_chars_per // 4)
        duration = entry.get("duration_s", "?")

        changes = entry.get("changes", entry.get("actions", []))
        lessons = entry.get("lessons", [])

        actions_str = format_list(changes, max_chars_per // 3)
        lessons_str = format_list(lessons, max_chars_per // 3)

        print(f"### Example {i} ({result})")
        print(f"- Task: {task}")
        if duration != "?":
            print(f"- Duration: {duration}s")
        print(f"- Actions: {actions_str}")
        print(f"- Lessons: {lessons_str}")
        print()
else:
    # --- Summary table mode ---
    print(f"Matching trajectories for '{task_type}': {len(matched)} found, showing {len(selected)}\n")
    # Header
    fmt = "{:<12} {:<20} {:<10} {:<8} {:<50}"
    print(fmt.format("ID", "Task Type", "Result", "Dur(s)", "Task"))
    print("-" * 104)
    for entry in selected:
        eid = entry.get("id", "?")[:12]
        etype = entry.get("task_type", "?")[:20]
        result = entry.get("result", "?")[:10]
        dur = str(entry.get("duration_s", "?"))[:8]
        task = truncate(entry.get("task", ""), 50)
        print(fmt.format(eid, etype, result, dur, task))

    print(f"\nTip: Add --inject to get prompt-injectable markdown output.")
PYEOF
