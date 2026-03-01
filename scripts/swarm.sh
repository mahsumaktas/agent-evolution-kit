#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# swarm.sh — Pattern-based multi-agent orchestration runner
#
# Usage:
#   swarm.sh --pattern consensus --agents "analyst,researcher,guardian" --task "Evaluate X"
#   swarm.sh --pattern pipeline --agents "researcher,analyst,writer" --task "Research and write about X"
#   swarm.sh --pattern escalation --task "Solve complex problem X"
#   swarm.sh --list
#
# Supported patterns: consensus, pipeline, fan-out, reflection, review-loop,
# red-team, escalation, circuit-breaker

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

# === PATHS ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_DIR="$AEK_HOME/config/swarm-patterns"
BRIDGE="$SCRIPT_DIR/bridge.sh"
CONSENSUS_PY="$SCRIPT_DIR/helpers/consensus.py"
CB_SCRIPT="$SCRIPT_DIR/circuit-breaker.sh"
MAKER_CHECKER="$SCRIPT_DIR/maker-checker.sh"
WORK_DIR="/tmp/swarm-$$"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === LOGGING ===
log()  { echo -e "${GREEN}[swarm]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[swarm]${NC} $1" >&2; }
err()  { echo -e "${RED}[swarm]${NC} $1" >&2; }
step() { echo -e "${CYAN}[swarm]${NC} $1" >&2; }

# === USAGE ===
usage() {
    cat >&2 << 'EOF'
Swarm Runner — Pattern-based multi-agent orchestration

Usage:
  swarm.sh --pattern <name> --agents "a,b,c" --task "..."
  swarm.sh --list

Options:
  --pattern <name>      Swarm pattern (consensus, pipeline, fan-out, etc.)
  --agents <list>       Comma-separated agent/role list
  --task <text>         Task description
  --consensus-type <t>  Override consensus type (majority, supermajority, unanimous, weighted, quorum)
  --list                List available patterns
  --dry-run             Show what would be executed without running
  -h, --help            Show this message

Examples:
  swarm.sh --pattern consensus --agents "analyst,researcher,guardian" --task "Evaluate PR #123"
  swarm.sh --pattern pipeline --agents "researcher,analyst,writer" --task "Research and write report"
  swarm.sh --pattern escalation --task "Solve complex problem"
EOF
    exit 1
}

# === YAML PARSER ===
# Simple grep/sed YAML parsing — single-level key:value only
yaml_get() {
    local file="$1" key="$2"
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$file" | sed 's/^"\(.*\)"$/\1/' | head -1
}

yaml_get_config() {
    local file="$1" key="$2"
    sed -n "/^config:/,/^[^ ]/{ s/^[[:space:]]*${key}:[[:space:]]*//p; }" "$file" | sed 's/^"\(.*\)"$/\1/' | head -1
}

yaml_get_array() {
    local file="$1" key="$2"
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*\[//p" "$file" | sed 's/\].*//;s/,/ /g;s/"//g' | head -1
}

# === BRIDGE WRAPPER ===
# Call bridge, return output
bridge_call() {
    local preset="${1:-analyze}" prompt="$2"
    local result
    result="$(bash "$BRIDGE" "--${preset}" --text --silent "$prompt" 2>/dev/null)" || {
        warn "Bridge call failed (preset=$preset)"
        echo "[BRIDGE_ERROR]"
        return 1
    }
    echo "$result"
}

# === LIST PATTERNS ===
list_patterns() {
    echo ""
    echo "Available Swarm Patterns:"
    echo "========================="
    echo ""
    for f in "$PATTERNS_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        local name desc flow agents_min
        name="$(yaml_get "$f" "name")"
        desc="$(yaml_get "$f" "description")"
        flow="$(yaml_get "$f" "flow")"
        agents_min="$(yaml_get "$f" "agents_min")"
        printf "  %-18s [flow: %-20s agents>=%s]\n" "$name" "$flow" "$agents_min"
        printf "    %s\n\n" "$desc"
    done
}

# === FLOW IMPLEMENTATIONS ===

# Sequential pipeline: A -> B -> C
flow_sequential() {
    local task="$1"
    shift
    local agents=("$@")
    local current_output="$task"
    local step_num=0
    local timeout_per_step
    timeout_per_step="$(yaml_get_config "$PATTERN_FILE" "timeout_per_step")"
    timeout_per_step="${timeout_per_step:-120}"
    local fail_fast
    fail_fast="$(yaml_get_config "$PATTERN_FILE" "fail_fast")"

    for agent in "${agents[@]}"; do
        step_num=$((step_num + 1))
        step "Pipeline step $step_num/$((${#agents[@]})): agent=$agent"

        local prompt="You are acting as: $agent
Task: $current_output
Provide your output for the next step in the pipeline."

        local output
        output="$(bridge_call "analyze" "$prompt")" || {
            if [[ "$fail_fast" == "true" ]]; then
                err "Pipeline failed at step $step_num (agent=$agent), fail_fast=true"
                return 1
            fi
            warn "Step $step_num failed, continuing with previous output"
            continue
        }
        current_output="$output"
        echo "$output" > "$WORK_DIR/step-${step_num}-${agent}.txt"
    done

    log "Pipeline completed ($step_num steps)"
    echo "$current_output"
}

# Parallel then vote (consensus)
flow_parallel_then_vote() {
    local task="$1"
    shift
    local agents=("$@")
    local consensus_type="${CONSENSUS_TYPE_OVERRIDE:-$(yaml_get_config "$PATTERN_FILE" "consensus_type")}"
    consensus_type="${consensus_type:-majority}"

    local votes_json="["
    local first=true
    local agent_idx=0

    for agent in "${agents[@]}"; do
        agent_idx=$((agent_idx + 1))
        step "Consensus agent $agent_idx/${#agents[@]}: $agent"

        local prompt="You are acting as: $agent
Task: $task

Evaluate the task and provide your vote. You MUST end your response with exactly one of these on its own line:
VOTE: APPROVE
VOTE: REJECT
VOTE: ABSTAIN

Provide brief reasoning before your vote."

        local output
        output="$(bridge_call "analyze" "$prompt")" || {
            warn "Agent $agent failed to respond, counting as ABSTAIN"
            output="VOTE: ABSTAIN"
        }

        echo "$output" > "$WORK_DIR/vote-${agent}.txt"

        # Parse vote
        local vote
        vote="$(echo "$output" | grep -oE 'VOTE:[[:space:]]*(APPROVE|REJECT|ABSTAIN)' | tail -1 | sed 's/VOTE:[[:space:]]*//')"
        vote="${vote:-ABSTAIN}"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            votes_json+=","
        fi
        votes_json+="{\"agent\":\"$agent\",\"vote\":\"$vote\"}"
    done
    votes_json+="]"

    echo "$votes_json" > "$WORK_DIR/votes.json"
    step "Running consensus engine (type=$consensus_type)"

    local result
    result="$(echo "$votes_json" | python3 "$CONSENSUS_PY" --type "$consensus_type")"
    echo "$result" > "$WORK_DIR/consensus-result.json"

    log "Consensus result:"
    echo "$result"
}

# Parallel then merge (fan-out)
flow_parallel_then_merge() {
    local task="$1"
    shift
    local agents=("$@")
    local merge_strategy
    merge_strategy="$(yaml_get_config "$PATTERN_FILE" "merge_strategy")"
    merge_strategy="${merge_strategy:-concatenate}"

    local merged=""
    local agent_idx=0

    for agent in "${agents[@]}"; do
        agent_idx=$((agent_idx + 1))
        step "Fan-out agent $agent_idx/${#agents[@]}: $agent"

        local prompt="You are acting as: $agent
Task: $task
Provide your perspective and analysis."

        local output
        output="$(bridge_call "analyze" "$prompt")" || {
            warn "Agent $agent failed"
            continue
        }

        echo "$output" > "$WORK_DIR/fanout-${agent}.txt"

        if [[ -n "$merged" ]]; then
            merged+=$'\n\n---\n\n'
        fi
        merged+="## Agent: $agent"$'\n\n'"$output"
    done

    log "Fan-out completed ($agent_idx agents)"
    echo "$merged"
}

# Self-reflection loop
flow_loop() {
    local task="$1"
    shift
    local agents=("$@")
    local agent="${agents[0]:-default}"
    local max_iterations
    max_iterations="$(yaml_get_config "$PATTERN_FILE" "max_iterations")"
    max_iterations="${max_iterations:-2}"

    step "Reflection: initial generation (agent=$agent)"
    local prompt="You are acting as: $agent
Task: $task
Provide your best response."

    local current_output
    current_output="$(bridge_call "analyze" "$prompt")" || {
        err "Initial generation failed"
        return 1
    }
    echo "$current_output" > "$WORK_DIR/reflection-iter-0.txt"

    local iter=1
    while [[ $iter -le $max_iterations ]]; do
        step "Reflection iteration $iter/$max_iterations: self-critique"

        local review_prompt="You are acting as: $agent (self-review mode)
You previously produced this output:

---
$current_output
---

Critically review your own output. If it is satisfactory, respond with exactly:
SELF_APPROVE

Otherwise, provide an improved version."

        local review_output
        review_output="$(bridge_call "analyze" "$review_prompt")" || {
            warn "Reflection iteration $iter failed"
            break
        }

        echo "$review_output" > "$WORK_DIR/reflection-iter-${iter}.txt"

        if echo "$review_output" | grep -q "SELF_APPROVE"; then
            log "Self-approved at iteration $iter"
            break
        fi

        current_output="$review_output"
        iter=$((iter + 1))
    done

    log "Reflection completed"
    echo "$current_output"
}

# Maker-checker review loop
flow_maker_checker() {
    local task="$1"
    shift
    local agents=("$@")

    if [[ -x "$MAKER_CHECKER" ]]; then
        step "Delegating to maker-checker.sh"
        local maker="${agents[0]:-maker}"
        local checker="${agents[1]:-checker}"
        local max_iterations
        max_iterations="$(yaml_get_config "$PATTERN_FILE" "max_iterations")"
        max_iterations="${max_iterations:-3}"
        local threshold
        threshold="$(yaml_get_config "$PATTERN_FILE" "threshold")"
        threshold="${threshold:-7}"

        bash "$MAKER_CHECKER" --maker "$maker" --checker "$checker" \
            --max-rounds "$max_iterations" --threshold "$threshold" \
            --task "$task" 2>&1
    else
        warn "maker-checker.sh not found, falling back to inline implementation"

        local maker="${agents[0]:-maker}"
        local checker="${agents[1]:-checker}"
        local max_iterations
        max_iterations="$(yaml_get_config "$PATTERN_FILE" "max_iterations")"
        max_iterations="${max_iterations:-3}"
        local threshold
        threshold="$(yaml_get_config "$PATTERN_FILE" "threshold")"
        threshold="${threshold:-7}"

        step "Maker ($maker): producing initial output"
        local maker_prompt="You are acting as: $maker
Task: $task
Produce the best output you can."

        local output
        output="$(bridge_call "analyze" "$maker_prompt")" || {
            err "Maker failed"
            return 1
        }

        local iter=1
        while [[ $iter -le $max_iterations ]]; do
            step "Checker ($checker): reviewing iteration $iter"
            local check_prompt="You are acting as: $checker
Review the following output and score it 1-10. If score >= $threshold, respond with:
APPROVED (score: N/10)

Otherwise, provide specific feedback for improvement.

Output to review:
---
$output
---"

            local review
            review="$(bridge_call "analyze" "$check_prompt")" || {
                warn "Checker failed at iteration $iter"
                break
            }

            echo "$review" > "$WORK_DIR/review-iter-${iter}.txt"

            if echo "$review" | grep -q "APPROVED"; then
                log "Approved at iteration $iter"
                echo "$output"
                return 0
            fi

            step "Maker ($maker): revising based on feedback"
            local revise_prompt="You are acting as: $maker
Original task: $task

Your previous output:
---
$output
---

Reviewer feedback:
---
$review
---

Revise your output based on the feedback."

            output="$(bridge_call "analyze" "$revise_prompt")" || {
                warn "Maker revision failed"
                break
            }
            echo "$output" > "$WORK_DIR/maker-iter-${iter}.txt"
            iter=$((iter + 1))
        done

        warn "Max iterations reached without approval"
        echo "$output"
    fi
}

# Adversarial red-team
flow_adversarial() {
    local task="$1"
    shift
    local agents=("$@")
    local producer="${agents[0]:-producer}"
    local attacker="${agents[1]:-attacker}"
    local judge="${agents[2]:-judge}"
    local max_rounds
    max_rounds="$(yaml_get_config "$PATTERN_FILE" "max_rounds")"
    max_rounds="${max_rounds:-2}"

    local round=1
    local producer_output=""

    while [[ $round -le $max_rounds ]]; do
        step "Red-team round $round/$max_rounds"

        # Producer
        local producer_prompt
        if [[ -z "$producer_output" ]]; then
            producer_prompt="You are acting as: $producer
Task: $task
Provide your best solution."
        else
            producer_prompt="You are acting as: $producer
Task: $task

Previous critique:
---
$attacker_output
---

Improve your solution based on the critique.
Previous solution:
---
$producer_output
---"
        fi

        step "  Producer ($producer)"
        producer_output="$(bridge_call "analyze" "$producer_prompt")" || {
            err "Producer failed"
            return 1
        }
        echo "$producer_output" > "$WORK_DIR/rt-producer-r${round}.txt"

        # Attacker
        step "  Attacker ($attacker)"
        local attacker_prompt="You are acting as: $attacker (adversarial reviewer)
Your job is to find flaws, weaknesses, and attack vectors in the following output.
Be thorough and aggressive in your critique.

Task context: $task

Output to attack:
---
$producer_output
---"

        local attacker_output
        attacker_output="$(bridge_call "analyze" "$attacker_prompt")" || {
            warn "Attacker failed"
            attacker_output="[No critique available]"
        }
        echo "$attacker_output" > "$WORK_DIR/rt-attacker-r${round}.txt"

        round=$((round + 1))
    done

    # Judge
    step "Judge ($judge): final evaluation"
    local judge_prompt="You are acting as: $judge (impartial evaluator)
Evaluate the following exchange between a producer and an attacker.

Task: $task

Final producer output:
---
$producer_output
---

Final attacker critique:
---
$attacker_output
---

Provide:
1. Overall quality score (1-10)
2. Key strengths
3. Remaining weaknesses
4. Final verdict: PASS or FAIL"

    local judge_output
    judge_output="$(bridge_call "analyze" "$judge_prompt")" || {
        err "Judge failed"
        return 1
    }
    echo "$judge_output" > "$WORK_DIR/rt-judge.txt"

    log "Red-team completed"
    echo "$judge_output"
}

# Cascade/escalation
flow_cascade() {
    local task="$1"
    local model_chain
    model_chain="$(yaml_get_array "$PATTERN_FILE" "model_chain")"
    model_chain="${model_chain:-haiku sonnet opus}"

    local prompt="Task: $task
Provide a thorough and complete response."

    for model in $model_chain; do
        step "Escalation: trying model=$model"

        local preset
        case "$model" in
            haiku)  preset="quick" ;;
            sonnet) preset="code" ;;
            opus)   preset="analyze" ;;
            *)      preset="analyze" ;;
        esac

        local output
        output="$(bridge_call "$preset" "$prompt")" || {
            warn "Model $model failed, escalating..."
            continue
        }

        # Success check — if no [BRIDGE_ERROR] and non-empty, consider it successful
        if [[ "$output" != *"[BRIDGE_ERROR]"* ]] && [[ -n "$output" ]]; then
            log "Cascade succeeded with model=$model"
            echo "$output"
            return 0
        fi

        warn "Model $model returned empty/error, escalating..."
    done

    err "All models in cascade failed"
    return 1
}

# Guarded execution with circuit breaker
flow_guarded() {
    local task="$1"
    shift
    local agents=("$@")
    local agent="${agents[0]:-default}"
    local cb_name="swarm-${agent}"
    local fallback
    fallback="$(yaml_get_config "$PATTERN_FILE" "fallback")"
    fallback="${fallback:-return_cached_or_error}"

    # Circuit breaker check
    if [[ -x "$CB_SCRIPT" ]]; then
        step "Circuit breaker check: $cb_name"
        if ! bash "$CB_SCRIPT" check "$cb_name" 2>/dev/null; then
            warn "Circuit breaker OPEN for $cb_name — using fallback: $fallback"
            echo "{\"status\":\"circuit_breaker_open\",\"agent\":\"$agent\",\"fallback\":\"$fallback\"}"
            return 1
        fi
    fi

    # Execute
    step "Guarded execution: agent=$agent"
    local prompt="You are acting as: $agent
Task: $task
Provide your response."

    local output
    if output="$(bridge_call "analyze" "$prompt")"; then
        if [[ "$output" != *"[BRIDGE_ERROR]"* ]] && [[ -n "$output" ]]; then
            # Record success
            [[ -x "$CB_SCRIPT" ]] && bash "$CB_SCRIPT" record "$cb_name" success 2>/dev/null
            log "Guarded execution succeeded"
            echo "$output"
            return 0
        fi
    fi

    # Record failure
    [[ -x "$CB_SCRIPT" ]] && bash "$CB_SCRIPT" record "$cb_name" failure 2>/dev/null
    err "Guarded execution failed"
    echo "{\"status\":\"execution_failed\",\"agent\":\"$agent\",\"fallback\":\"$fallback\"}"
    return 1
}

# === MAIN ===
PATTERN=""
AGENTS_STR=""
TASK=""
LIST=false
DRY_RUN=false
CONSENSUS_TYPE_OVERRIDE=""

if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pattern)  PATTERN="$2"; shift 2 ;;
        --agents)   AGENTS_STR="$2"; shift 2 ;;
        --task)     TASK="$2"; shift 2 ;;
        --consensus-type) CONSENSUS_TYPE_OVERRIDE="$2"; shift 2 ;;
        --list)     LIST=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)  usage ;;
        *)          err "Unknown parameter: $1"; usage ;;
    esac
done

# List mode
if [[ "$LIST" == "true" ]]; then
    list_patterns
    exit 0
fi

# Validation
if [[ -z "$PATTERN" ]]; then
    err "--pattern required"
    usage
fi

if [[ -z "$TASK" ]]; then
    err "--task required"
    usage
fi

PATTERN_FILE="$PATTERNS_DIR/${PATTERN}.yaml"
if [[ ! -f "$PATTERN_FILE" ]]; then
    err "Pattern not found: $PATTERN_FILE"
    err "Available patterns:"
    ls "$PATTERNS_DIR"/*.yaml 2>/dev/null | xargs -I{} basename {} .yaml | sed 's/^/  /' >&2
    exit 1
fi

# Read flow from YAML
FLOW="$(yaml_get "$PATTERN_FILE" "flow")"
AGENTS_MIN="$(yaml_get "$PATTERN_FILE" "agents_min")"

if [[ -z "$FLOW" ]]; then
    err "'flow' field not found in pattern file: $PATTERN_FILE"
    exit 1
fi

# Parse agent list
CLEAN_AGENTS=()
if [[ -n "$AGENTS_STR" ]]; then
    IFS=',' read -ra AGENTS <<< "$AGENTS_STR"
    for a in "${AGENTS[@]}"; do
        a="$(echo "$a" | xargs)" # trim
        [[ -n "$a" ]] && CLEAN_AGENTS+=("$a")
    done
fi

# Cascade and guarded don't require agents
if [[ "$FLOW" != "cascade" ]] && [[ ${#CLEAN_AGENTS[@]} -lt ${AGENTS_MIN:-1} ]]; then
    # No agents specified — assign defaults
    if [[ ${#CLEAN_AGENTS[@]} -eq 0 ]]; then
        case "$FLOW" in
            parallel_then_vote) CLEAN_AGENTS=("analyst" "researcher" "guardian") ;;
            sequential)         CLEAN_AGENTS=("researcher" "analyst") ;;
            parallel_then_merge) CLEAN_AGENTS=("analyst-1" "analyst-2") ;;
            loop)               CLEAN_AGENTS=("reflector") ;;
            maker_checker)      CLEAN_AGENTS=("maker" "checker") ;;
            adversarial)        CLEAN_AGENTS=("producer" "attacker" "judge") ;;
            guarded)            CLEAN_AGENTS=("executor") ;;
            *)                  CLEAN_AGENTS=("agent-1") ;;
        esac
        warn "No agents specified, using defaults: ${CLEAN_AGENTS[*]:-}"
    fi
fi

# Work directory
mkdir -p "$WORK_DIR"

# Summary
log "Pattern: $PATTERN (flow=$FLOW)"
log "Agents: ${CLEAN_AGENTS[*]:-none}"
log "Task: $(echo "$TASK" | head -c 100)"
log "Work dir: $WORK_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: would run with the above configuration"
    exit 0
fi

# Dependency checks
if [[ ! -x "$BRIDGE" ]]; then
    err "Bridge not found: $BRIDGE"
    exit 1
fi

if [[ "$FLOW" == "parallel_then_vote" ]] && [[ ! -f "$CONSENSUS_PY" ]]; then
    err "Consensus engine not found: $CONSENSUS_PY"
    exit 1
fi

# Flow dispatch
case "$FLOW" in
    sequential)
        flow_sequential "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    parallel_then_vote)
        flow_parallel_then_vote "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    parallel_then_merge)
        flow_parallel_then_merge "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    loop)
        flow_loop "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    maker_checker)
        flow_maker_checker "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    adversarial)
        flow_adversarial "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    cascade)
        flow_cascade "$TASK"
        ;;
    guarded)
        flow_guarded "$TASK" "${CLEAN_AGENTS[@]}"
        ;;
    *)
        err "Unsupported flow type: $FLOW"
        exit 1
        ;;
esac

EXIT_CODE=$?
log "Swarm completed (exit=$EXIT_CODE, work_dir=$WORK_DIR)"
exit $EXIT_CODE
