#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# predict.sh — Predictive engine using trajectory pool analysis
#
# Analyzes past task executions to predict outcomes, identify risks,
# and discover opportunities. Uses bridge.sh for LLM analysis when
# available, falls back to heuristic summary.
#
# Usage:
#   predict.sh --weekly          Weekly prediction report
#   predict.sh --task "type"     Predict success for a task type
#   predict.sh --risk            Risk analysis
#   predict.sh --opportunity     Opportunity detection

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
BRIDGE="$AEK_HOME/scripts/bridge.sh"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
EVOLUTION_LOG="$AEK_HOME/memory/evolution-log.md"
REFLECTIONS_DIR="$AEK_HOME/memory/reflections"
KNOWLEDGE_DIR="$AEK_HOME/memory/knowledge"
PREDICT_DIR="$AEK_HOME/memory/predictions"

# === Colors ===
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[predict]${NC} $1" >&2; }
step() { echo -e "${CYAN}[predict]${NC} === $1 ===" >&2; }

# === Parse Arguments ===
MODE="weekly"
TASK_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --weekly)      MODE="weekly"; shift;;
        --task)        MODE="task"; TASK_TYPE="$2"; shift 2;;
        --risk)        MODE="risk"; shift;;
        --opportunity) MODE="opportunity"; shift;;
        --help|-h)
            echo "Usage: predict.sh [--weekly | --task \"type\" | --risk | --opportunity]"
            exit 0;;
        *) shift;;
    esac
done

mkdir -p "$PREDICT_DIR"

# === Gather Data ===
step "DATA COLLECTION"

TRAJECTORY_STATS=$(python3 -c "
import json, os
from collections import Counter, defaultdict

try:
    with open('$TRAJECTORY') as f:
        pool = json.load(f)
    if isinstance(pool, list):
        entries = pool
    else:
        entries = pool.get('entries', pool.get('trajectories', []))
except:
    entries = []

if not entries:
    print('TRAJECTORY_EMPTY=true')
    print('TOTAL_TASKS=0')
    exit()

total = len(entries)
success = sum(1 for e in entries if e.get('result','').upper() in ('SUCCESS','COMPLETED'))
failed = sum(1 for e in entries if e.get('result','').upper() in ('FAILED','ERROR'))
partial = total - success - failed

# By agent
agent_stats = defaultdict(lambda: {'success': 0, 'total': 0, 'tokens': 0})
for e in entries:
    agent = e.get('agent', 'unknown')
    agent_stats[agent]['total'] += 1
    agent_stats[agent]['tokens'] += e.get('tokens_used', e.get('turns', 0))
    if e.get('result','').upper() in ('SUCCESS','COMPLETED'):
        agent_stats[agent]['success'] += 1

# By task type
type_stats = defaultdict(lambda: {'success': 0, 'total': 0})
for e in entries:
    tt = e.get('task_type', e.get('task', 'unknown'))[:30]
    type_stats[tt]['total'] += 1
    if e.get('result','').upper() in ('SUCCESS','COMPLETED'):
        type_stats[tt]['success'] += 1

print(f'TOTAL_TASKS={total}')
print(f'SUCCESS_RATE={success/total*100:.1f}')
print(f'FAILED={failed}')
print(f'PARTIAL={partial}')
print()
print('AGENT_STATS:')
for agent, stats in sorted(agent_stats.items()):
    rate = stats['success']/stats['total']*100 if stats['total'] > 0 else 0
    print(f'  {agent}: {rate:.0f}% success ({stats[\"total\"]} tasks)')
print()
print('TASK_TYPE_STATS:')
for tt, stats in sorted(type_stats.items()):
    rate = stats['success']/stats['total']*100 if stats['total'] > 0 else 0
    print(f'  {tt}: {rate:.0f}% success ({stats[\"total\"]} tasks)')
" 2>/dev/null) || TRAJECTORY_STATS="TRAJECTORY_EMPTY=true"

# Reflection count
REFLECTION_COUNT=$(find "$REFLECTIONS_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

# Knowledge count
KNOWLEDGE_COUNT=$(find "$KNOWLEDGE_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

log "Trajectory: $(echo "$TRAJECTORY_STATS" | head -1)"
log "Reflections: $REFLECTION_COUNT files"
log "Knowledge: $KNOWLEDGE_COUNT files"

# === Generate Prediction ===
step "PREDICTION — $MODE"

PREDICTION_PROMPT="You are a Predictive Engine for an AI agent system. Analyze past data and produce actionable predictions.

MODE: $MODE
$([ -n "$TASK_TYPE" ] && echo "TASK TYPE: $TASK_TYPE")

AVAILABLE DATA:
$TRAJECTORY_STATS

Reflection count: $REFLECTION_COUNT
Knowledge base size: $KNOWLEDGE_COUNT files

TASK ($MODE):
$(case $MODE in
    weekly)
        echo "Generate a weekly prediction report:
1. Which task types will succeed next week? (confidence %)
2. Which agents are at risk? (low success rates)
3. Token consumption trend (increasing/decreasing forecast)
4. Top 3 improvement opportunities
5. Proactive recommendations for the operator";;
    task)
        echo "Predict outcome for task type: $TASK_TYPE
1. Success probability (%) and confidence level
2. Expected duration and token consumption
3. Potential risks
4. Recommended strategy
5. Best model selection";;
    risk)
        echo "Risk analysis:
1. Top 3 highest risk areas (agent/task/system)
2. Probability and impact assessment for each
3. Preventive measures
4. Items requiring immediate attention
5. Overall system health assessment";;
    opportunity)
        echo "Opportunity analysis:
1. Underexploited capabilities in current data
2. New tool suggestions (what tools should be built?)
3. New automation opportunities
4. Strategic improvement areas
5. Self-improvement opportunities for the system";;
esac)

FORMAT: Markdown, concise and actionable"

# Try LLM bridge, fall back to heuristic
if [[ -x "$BRIDGE" ]]; then
    PREDICTION=$(bash "$BRIDGE" --analyze --text --silent "$PREDICTION_PROMPT" 2>/dev/null) || {
        log "LLM bridge unavailable, generating heuristic report"
        PREDICTION=""
    }
fi

# Fallback: heuristic report
if [[ -z "${PREDICTION:-}" ]]; then
    PREDICTION="# Prediction Report - $(date +%Y-%m-%d) ($MODE)

## Data Summary
$TRAJECTORY_STATS

## Heuristic Analysis
- Reflections available: $REFLECTION_COUNT
- Knowledge files: $KNOWLEDGE_COUNT
- Mode: $MODE

## Recommendations
- Ensure trajectory pool is populated with task results
- Run tasks through the metrics system for better data
- Use bridge.sh with an LLM for deeper analysis
- Review failed trajectories for improvement patterns

*Note: This is a heuristic report. Connect bridge.sh to an LLM CLI for AI-powered predictions.*"
fi

# === Save ===
PREDICT_FILE="$PREDICT_DIR/$(date +%Y-%m-%d)-${MODE}.md"
echo "$PREDICTION" > "$PREDICT_FILE"
log "Prediction saved: $PREDICT_FILE"

# === Output ===
echo ""
echo "$PREDICTION"
