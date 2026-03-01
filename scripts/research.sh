#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# research.sh — Autonomous research engine
#
# Performs research on topics relevant to the agent system's improvement.
# Can auto-select topics from failed trajectories or knowledge gaps.
#
# Usage:
#   research.sh --topic "subject"     Research a specific topic
#   research.sh --auto                Pick topic from trajectory failures
#   research.sh --trend               Scan recent technology trends
#   research.sh --gap-analysis        Analyze knowledge gaps

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
BRIDGE="$AEK_HOME/scripts/bridge.sh"
KNOWLEDGE_DIR="$AEK_HOME/memory/knowledge"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
REFLECTIONS_DIR="$AEK_HOME/memory/reflections"
RESEARCH_LOG="$AEK_HOME/memory/research-log.md"

# === Colors ===
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[research]${NC} $1" >&2; }
step() { echo -e "${CYAN}[research]${NC} === $1 ===" >&2; }

# === Parse Arguments ===
MODE="topic"
TOPIC=""
DEPTH="standard"  # standard | deep

while [[ $# -gt 0 ]]; do
    case $1 in
        --topic) MODE="topic"; TOPIC="$2"; shift 2;;
        --auto)  MODE="auto"; shift;;
        --trend) MODE="trend"; shift;;
        --gap-analysis) MODE="gap"; shift;;
        --deep)  DEPTH="deep"; shift;;
        --help|-h)
            echo "Usage: research.sh [--topic \"subject\" | --auto | --trend | --gap-analysis] [--deep]"
            exit 0;;
        *) TOPIC="$1"; shift;;
    esac
done

mkdir -p "$KNOWLEDGE_DIR"

# === Auto Topic Selection ===
if [[ "$MODE" == "auto" ]]; then
    step "AUTO TOPIC SELECTION"
    log "Analyzing trajectory pool and reflections..."

    TOPIC=$(python3 -c "
import json, os, glob

# Analyze trajectory pool for weak areas
try:
    with open('$TRAJECTORY') as f:
        pool = json.load(f)
    if isinstance(pool, list):
        entries = pool
    else:
        entries = pool.get('entries', pool.get('trajectories', []))
    failed = [e for e in entries if e.get('result','').upper() in ('FAILED','ERROR')]
    fail_types = {}
    for e in failed:
        t = e.get('task_type', e.get('task', 'unknown'))
        fail_types[t] = fail_types.get(t, 0) + 1
    if fail_types:
        worst = max(fail_types, key=fail_types.get)
        print(f'Most failed task type: {worst} -- research improvement methods')
    else:
        # Check reflections
        reflections = glob.glob('$REFLECTIONS_DIR/*/*.md') + glob.glob('$REFLECTIONS_DIR/*.md')
        if reflections:
            print('Agent reflection analysis -- recurring issues and solutions')
        else:
            print('AI agent self-improvement techniques and autonomous tool generation')
except:
    print('AI agent self-improvement techniques and autonomous tool generation')
" 2>/dev/null)

    log "Selected topic: $TOPIC"
fi

if [[ "$MODE" == "trend" ]]; then
    TOPIC="Recent AI/ML developments, new tools, new frameworks, and their practical applications for agent systems"
fi

if [[ "$MODE" == "gap" ]]; then
    step "KNOWLEDGE GAP ANALYSIS"
    TOPIC=$(python3 -c "
import os, glob

# Check what knowledge exists
existing = set()
for f in glob.glob('$KNOWLEDGE_DIR/*.md'):
    existing.add(os.path.basename(f).replace('.md',''))

# Expected knowledge areas for an agent system
expected = [
    'ai-agent-frameworks', 'prompt-engineering', 'mcp-protocol',
    'llm-cli-tools', 'typescript-best-practices', 'python-automation',
    'devops-patterns', 'security-best-practices', 'monitoring-patterns',
    'self-evolution-techniques', 'multi-agent-coordination'
]

missing = [e for e in expected if not any(e in x for x in existing)]
if missing:
    print(f'Knowledge gaps: {\", \".join(missing[:3])} -- research these areas')
else:
    print('Update and deepen existing knowledge areas')
" 2>/dev/null)

    log "Gap analysis result: $TOPIC"
fi

[[ -z "$TOPIC" ]] && { echo "No topic specified. Use --topic, --auto, --trend, or --gap-analysis."; exit 1; }

# === Research ===
step "RESEARCH STARTED"
log "Topic: $TOPIC"
log "Depth: $DEPTH"

BRIDGE_MODE="--research"
[[ "$DEPTH" == "standard" ]] && BRIDGE_MODE="--analyze"

RESEARCH_PROMPT="You are an Autonomous Research Engine for an AI agent system. Your purpose: improve system capabilities.

RESEARCH TOPIC: $TOPIC

TASK:
1. Research this topic thoroughly (web search, docs, GitHub)
2. Summarize the top 5-10 findings
3. Write a CONCRETE action item for each finding
4. How does this relate to running an autonomous multi-agent system?

FORMAT:
# Research: [topic]
Date: [today's date]

## Summary
[2-3 sentences]

## Findings
1. **[finding title]**
   - Detail: [explanation]
   - Source: [URL or reference]
   - Action: [what to do]

## Recommendations
- [concrete recommendation 1]
- [concrete recommendation 2]
- [concrete recommendation 3]

## System Improvement Implications
- [how the system can leverage this]
"

# Try LLM bridge
RESULT=""
if [[ -x "$BRIDGE" ]]; then
    RESULT=$(bash "$BRIDGE" $BRIDGE_MODE --text --silent "$RESEARCH_PROMPT" 2>/dev/null) || {
        log "LLM bridge call failed"
        RESULT=""
    }
fi

# Fallback
if [[ -z "$RESULT" ]]; then
    RESULT="# Research: $TOPIC
Date: $(date +%Y-%m-%d)

## Summary
Research topic queued but LLM bridge is unavailable. Manual research needed.

## Topic Details
- **Subject:** $TOPIC
- **Mode:** $MODE
- **Depth:** $DEPTH

## Next Steps
- Set up bridge.sh with an LLM CLI for automated research
- Manually research this topic and save findings here
- Use web search for: $TOPIC

*Note: Connect bridge.sh to an LLM CLI for AI-powered research.*"
fi

# === Save Findings ===
step "SAVING FINDINGS"

SAFE_TOPIC=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c50)
FINDING_FILE="$KNOWLEDGE_DIR/$(date +%Y-%m-%d)-${SAFE_TOPIC}.md"

echo "$RESULT" > "$FINDING_FILE"
log "Findings saved: $FINDING_FILE"

# === Update Research Log ===
mkdir -p "$(dirname "$RESEARCH_LOG")"
TIMESTAMP=$(date +%Y-%m-%d)
cat >> "$RESEARCH_LOG" << EOF

## $TIMESTAMP -- $TOPIC
- **Mode:** $MODE
- **Depth:** $DEPTH
- **File:** $FINDING_FILE
- **Status:** COMPLETED
EOF

log "Research log updated"

# === Output Summary ===
echo ""
echo "=== RESEARCH COMPLETED ==="
echo "Topic:  $TOPIC"
echo "File:   $FINDING_FILE"
echo "Log:    $RESEARCH_LOG"
echo ""
echo "$RESULT" | head -20
