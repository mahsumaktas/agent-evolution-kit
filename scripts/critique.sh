#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# critique.sh — Cross-Agent Critique (MAR Pattern)
# Multi-agent review: one agent evaluates another agent's output.
#
# Based on: MAR (arxiv 2512.20845), docs/cross-agent-critique.md
#
# Usage:
#   critique.sh --output <file> --agent <producer>
#   critique.sh --matrix
#   critique.sh --batch
set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
BRIDGE="$AEK_HOME/scripts/bridge.sh"
CRITIQUE_DIR="$AEK_HOME/memory/critiques"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
TODAY=$(date +%Y-%m-%d)
MAX_DAILY_CRITIQUES=5
MAX_CONTENT_CHARS=2000
MAX_BATCH_ITEMS=3

# --- Colors ---
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

# --- Critique Matrix ---
# Format: PRODUCER:CRITIC:AREA
CRITIQUE_MATRIX=(
    "researcher-agent:analyst-agent:Research depth, source diversity"
    "social-agent:writer-agent:Tone, engagement, accuracy"
    "financial-agent:guardian-agent:Risk assessment, assumptions"
    "writer-agent:social-agent:Social media fit"
    "analyst-agent:researcher-agent:Completeness, missing areas"
    "metrics-agent:guardian-agent:Measurement accuracy"
)
DEFAULT_CRITIC="orchestrator"
DEFAULT_AREA="General quality review"

# --- Helper Functions ---

# Count today's critiques
count_today_critiques() {
    find "$CRITIQUE_DIR" -maxdepth 1 -name "${TODAY}-*.md" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Daily limit check
check_daily_limit() {
    local count
    count=$(count_today_critiques)
    if [[ "$count" -ge "$MAX_DAILY_CRITIQUES" ]]; then
        err "Daily critique limit exceeded ($count/$MAX_DAILY_CRITIQUES). Try again tomorrow."
        exit 1
    fi
    local remaining=$((MAX_DAILY_CRITIQUES - count))
    log "Daily critiques: $count/$MAX_DAILY_CRITIQUES (remaining: $remaining)"
    echo "$remaining"
}

# Find critic and area from matrix
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

# Check bridge availability
check_bridge() {
    if [[ ! -x "$BRIDGE" ]]; then
        err "bridge.sh not found: $BRIDGE"
        exit 127
    fi
}

# Extract verdict (APPROVE / SUGGEST / FLAG)
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

# --- Usage ---
usage() {
    cat >&2 <<'EOF'
Cross-Agent Critique — MAR Pattern

Usage:
  critique.sh --output <file> --agent <producer>   Evaluate an output
  critique.sh --matrix                              Show the critique matrix
  critique.sh --batch                               Evaluate recent high-impact tasks

Options:
  --output <file>    File path to evaluate
  --agent <name>     Producer agent name (researcher-agent, social-agent, financial-agent, etc.)
  --matrix           Show critique assignment matrix
  --batch            Evaluate high-impact tasks from last 7 days of trajectory pool
  --help, -h         Show this help message

Examples:
  critique.sh --output memory/reflections/researcher-agent/2026-03-01.md --agent researcher-agent
  critique.sh --batch
EOF
    exit 1
}

# --- --matrix command ---
cmd_matrix() {
    echo ""
    echo -e "${BOLD}  Cross-Agent Critique Matrix (MAR Pattern)${NC}"
    echo -e "  ${CYAN}============================================${NC}"
    echo ""
    printf "  ${BOLD}%-20s  %-18s  %s${NC}\n" "Producer" "Reviewer" "Focus Area"
    printf "  %-20s  %-18s  %s\n" "--------" "--------" "----------"
    for entry in "${CRITIQUE_MATRIX[@]}"; do
        local p c a
        p=$(echo "$entry" | cut -d: -f1)
        c=$(echo "$entry" | cut -d: -f2)
        a=$(echo "$entry" | cut -d: -f3-)
        printf "  %-20s  %-18s  %s\n" "$p" "$c" "$a"
    done
    printf "  %-20s  %-18s  %s\n" "* (other)" "$DEFAULT_CRITIC" "$DEFAULT_AREA"
    echo ""
    echo -e "  ${YELLOW}Daily limit: $MAX_DAILY_CRITIQUES | Today: $(count_today_critiques)${NC}"
    echo ""
}

# --- --output --agent command ---
cmd_critique() {
    local output_file="$1"
    local producer="$2"

    # File check
    if [[ ! -f "$output_file" ]]; then
        err "File not found: $output_file"
        exit 1
    fi

    check_bridge

    # Daily limit
    local remaining
    remaining=$(check_daily_limit)
    if [[ "$remaining" -le 0 ]]; then
        exit 1
    fi

    # Find critic and area
    local lookup_result critic area
    lookup_result=$(lookup_critic "$producer")
    critic=$(echo "$lookup_result" | cut -d: -f1)
    area=$(echo "$lookup_result" | cut -d: -f2-)

    log "Producer: $producer | Reviewer: $critic | Focus: $area"

    # Read content (max 2000 chars)
    local content
    content=$(head -c "$MAX_CONTENT_CHARS" "$output_file")

    if [[ -z "$content" ]]; then
        err "File is empty: $output_file"
        exit 1
    fi

    # Build critique prompt
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

    # Call bridge (--quick --text --silent)
    log "Calling bridge (haiku, quick mode)..."
    local result
    result=$(BRIDGE_CALLER="critique-${critic}" "$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null) || {
        local exit_code=$?
        err "Bridge call failed (exit: $exit_code)"
        exit "$exit_code"
    }

    if [[ -z "$result" ]]; then
        err "Bridge returned empty output"
        exit 1
    fi

    # Save to file
    local critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}.md"
    {
        echo "# Critique: ${TODAY} - ${critic} reviews ${producer}"
        echo ""
        echo "**File:** $(basename "$output_file")"
        echo "**Reviewer:** ${critic} | **Focus:** ${area}"
        echo ""
        echo "$result"
    } > "$critique_file"

    log "Critique saved: $critique_file"

    # Extract verdict
    local verdict
    verdict=$(parse_verdict "$result")

    # Show summary
    echo ""
    echo -e "${BOLD}  Critique Result${NC}"
    echo -e "  ${CYAN}=================${NC}"
    echo -e "  Producer:  ${producer}"
    echo -e "  Reviewer:  ${critic}"
    echo -e "  Focus:     ${area}"
    case "$verdict" in
        APPROVE) echo -e "  Verdict:   ${GREEN}${verdict}${NC}" ;;
        SUGGEST) echo -e "  Verdict:   ${YELLOW}${verdict}${NC}" ;;
        FLAG)    echo -e "  Verdict:   ${RED}${verdict}${NC}" ;;
        *)       echo -e "  Verdict:   ${verdict}" ;;
    esac
    echo -e "  File:      ${critique_file}"
    echo ""

    # Show critique content
    echo "$result"
}

# --- --batch command ---
cmd_batch() {
    check_bridge

    # Daily limit
    local remaining
    remaining=$(check_daily_limit)
    if [[ "$remaining" -le 0 ]]; then
        exit 1
    fi

    # Trajectory pool check
    if [[ ! -f "$TRAJECTORY" ]]; then
        err "Trajectory pool not found: $TRAJECTORY"
        exit 1
    fi

    log "Searching for high-impact tasks from last 7 days in trajectory pool..."

    # Parse trajectory with Python — last 7 days, high cost/duration, known producer
    local batch_items
    batch_items=$(python3 - "$TRAJECTORY" "$MAX_BATCH_ITEMS" <<'PYEOF'
import json, sys, os
from datetime import datetime, timedelta

trajectory_file = sys.argv[1]
max_items = int(sys.argv[2])

# Known producers in the matrix
known_producers = {
    "researcher-agent", "analyst-agent", "social-agent",
    "writer-agent", "financial-agent", "guardian-agent", "metrics-agent"
}

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

    # Only last 7 days
    if dt.replace(tzinfo=None) < cutoff:
        continue

    # Agent/caller info
    agent = e.get("agent", e.get("caller", "")).lower()
    # Does the agent name match a known producer?
    matched_producer = None
    for p in known_producers:
        if p in agent:
            matched_producer = p
            break

    if not matched_producer:
        continue

    # Impact score: cost + duration based
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

# Sort by highest impact
candidates.sort(key=lambda x: x["impact"], reverse=True)

# Take first N
for item in candidates[:max_items]:
    # TAB-separated: producer\ttask\tid
    print(f"{item['producer']}\t{item['task']}\t{item['id']}")
PYEOF
    ) || true

    if [[ -z "$batch_items" ]]; then
        log "No high-impact tasks from known producers found in last 7 days."
        exit 0
    fi

    local count=0
    while IFS=$'\t' read -r producer task traj_id; do
        # Re-check daily limit
        local current_count
        current_count=$(count_today_critiques)
        if [[ "$current_count" -ge "$MAX_DAILY_CRITIQUES" ]]; then
            warn "Daily limit exceeded, skipping remaining batch."
            break
        fi

        count=$((count + 1))
        log "Batch [$count]: evaluating $producer task (traj: $traj_id)"

        # Find critic and area
        local lookup_result critic area
        lookup_result=$(lookup_critic "$producer")
        critic=$(echo "$lookup_result" | cut -d: -f1)
        area=$(echo "$lookup_result" | cut -d: -f2-)

        # Prompt — use trajectory task content instead of file
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
        result=$(BRIDGE_CALLER="critique-batch-${critic}" "$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null) || {
            warn "Batch critique failed: $producer ($traj_id), skipping."
            continue
        }

        if [[ -z "$result" ]]; then
            warn "Batch critique empty output: $producer ($traj_id), skipping."
            continue
        fi

        # Save
        local critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}-batch.md"
        # If same file exists, add suffix
        if [[ -f "$critique_file" ]]; then
            critique_file="${CRITIQUE_DIR}/${TODAY}-${producer}-${critic}-batch-${count}.md"
        fi
        {
            echo "# Batch Critique: ${TODAY} - ${critic} reviews ${producer}"
            echo ""
            echo "**Trajectory:** ${traj_id}"
            echo "**Reviewer:** ${critic} | **Focus:** ${area}"
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
    log "Batch completed: $count tasks evaluated."
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
        *)          err "Unknown option: $1"; usage ;;
    esac
done

# Mode determination
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

# No mode selected
if [[ -n "$OUTPUT_FILE" && -z "$AGENT_NAME" ]]; then
    err "--agent parameter is required"
    exit 1
fi

if [[ -z "$OUTPUT_FILE" && -n "$AGENT_NAME" ]]; then
    err "--output parameter is required"
    exit 1
fi

err "Please select a command: --matrix, --batch, or --output <file> --agent <name>"
usage
