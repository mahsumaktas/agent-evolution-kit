#!/usr/bin/env bash
set -euo pipefail

# Oracle DAG Runner — Dependency-aware workflow execution via Blackboard
# Usage: dag.sh <command> [args]
# Commands:
#   run <workflow.json>           Execute a DAG workflow
#   status <workflow_name>        Check workflow status
#   create <name> <steps_json>    Create workflow from inline JSON
#   list                          List recent workflows
#   retry <workflow_name>         Retry failed tasks in workflow
#   cancel <workflow_name>        Cancel pending tasks in workflow
#   template                      Print a template workflow JSON
#   --help                        Show this help
#
# Workflow JSON format:
# {
#   "name": "my-workflow",
#   "steps": [
#     {"id": "step1", "agent": "primary-agent", "action": "exec", "payload": "echo hello", "depends": []},
#     {"id": "step2", "agent": "social-agent", "action": "cron-run", "payload": "job-id-here", "depends": ["step1"]},
#     {"id": "step3", "agent": "finance-agent", "action": "spawn", "payload": "analyze AAPL", "depends": ["step1"]}
#   ]
# }

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BB="${SCRIPT_DIR}/blackboard.sh"
readonly WORKFLOWS_DIR="${HOME}/.agent-evolution/workflows"
readonly SCRIPT_NAME="$(basename "$0")"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${BLUE}[DAG]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

show_help() {
  head -22 "$0" | grep '^#' | sed 's/^# *//'
  exit 0
}

ensure_dirs() {
  mkdir -p "$WORKFLOWS_DIR"
}

# Execute a single step based on action type
execute_step() {
  local step_id="$1" agent="$2" action="$3" payload="$4" workflow="$5"
  
  log "Executing step ${step_id} (${action}) on ${agent}..."
  "$BB" set "wf:${workflow}:${step_id}:status" "running" "$agent" 2>/dev/null
  "$BB" publish "dag.step.started" "{\"workflow\":\"$workflow\",\"step\":\"$step_id\",\"agent\":\"$agent\"}" "_system" "$agent" 2>/dev/null
  
  local exit_code=0
  local result=""
  
  case "$action" in
    exec)
      result=$(eval "$payload" 2>&1) || exit_code=$?
      ;;
    spawn)
      # Use sessions_spawn via agent-system CLI or direct API — for now exec-based
      result="spawn:${agent}:${payload}"
      log "  → Would spawn: agent=${agent}, task='${payload}'"
      ;;
    cron-run)
      # Trigger a cron job
      result="cron-trigger:${payload}"
      log "  → Would trigger cron job: ${payload}"
      ;;
    blackboard-set)
      local bb_key bb_val
      bb_key=$(echo "$payload" | cut -d= -f1)
      bb_val=$(echo "$payload" | cut -d= -f2-)
      "$BB" set "$bb_key" "$bb_val" "$agent" 2>/dev/null
      result="set:${bb_key}=${bb_val}"
      ;;
    webhook)
      result=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$payload" 2>&1) || exit_code=$?
      ;;
    notify)
      result="notify:${payload}"
      log "  → Notification: ${payload}"
      ;;
    *)
      err "Unknown action: ${action}"
      exit_code=1
      result="unknown action"
      ;;
  esac
  
  if [[ $exit_code -eq 0 ]]; then
    "$BB" set "wf:${workflow}:${step_id}:status" "done" "$agent" 2>/dev/null
    "$BB" set "wf:${workflow}:${step_id}:result" "${result:0:500}" "$agent" 2>/dev/null
    "$BB" publish "dag.step.done" "{\"workflow\":\"$workflow\",\"step\":\"$step_id\"}" "$agent" "_system" 2>/dev/null
    ok "Step ${step_id} completed"
  else
    "$BB" set "wf:${workflow}:${step_id}:status" "failed" "$agent" 2>/dev/null
    "$BB" set "wf:${workflow}:${step_id}:error" "${result:0:500}" "$agent" 2>/dev/null
    "$BB" publish "dag.step.failed" "{\"workflow\":\"$workflow\",\"step\":\"$step_id\",\"error\":\"${result:0:100}\"}" "$agent" "_system" 2>/dev/null
    err "Step ${step_id} failed (exit ${exit_code})"
  fi
  
  return $exit_code
}

# Check if all dependencies of a step are done
deps_met() {
  local workflow="$1" deps_json="$2"
  
  if [[ "$deps_json" == "[]" || -z "$deps_json" ]]; then
    return 0
  fi
  
  # Parse deps array
  local deps
  deps=$(echo "$deps_json" | python3 -c "import sys,json; [print(d) for d in json.load(sys.stdin)]" 2>/dev/null)
  
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local status
    status=$("$BB" get "wf:${workflow}:${dep}:status" "_global" 2>/dev/null || echo "pending")
    if [[ "$status" != "done" ]]; then
      return 1
    fi
  done <<< "$deps"
  
  return 0
}

cmd_run() {
  local workflow_file="${1:?workflow file required}"
  ensure_dirs
  
  if [[ ! -f "$workflow_file" ]]; then
    err "Workflow file not found: ${workflow_file}"
    exit 1
  fi
  
  local wf_json
  wf_json=$(cat "$workflow_file")
  local wf_name
  wf_name=$(echo "$wf_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
  local steps
  steps=$(echo "$wf_json" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(json.dumps(s)) for s in d['steps']]")
  local total
  total=$(echo "$steps" | wc -l | tr -d ' ')
  
  log "Starting workflow: ${wf_name} (${total} steps)"
  "$BB" set "wf:${wf_name}:status" "running" "_global" 2>/dev/null
  "$BB" set "wf:${wf_name}:started_at" "$(date '+%Y-%m-%dT%H:%M:%S')" "_global" 2>/dev/null
  "$BB" publish "dag.workflow.started" "{\"name\":\"$wf_name\",\"steps\":$total}" "_system" "_all" 2>/dev/null
  
  # Copy workflow for reference
  cp "$workflow_file" "${WORKFLOWS_DIR}/${wf_name}.json" 2>/dev/null || true
  
  # Topological execution: keep looping until all done or stuck
  local max_iterations=$((total * 3))
  local iteration=0
  local completed=0
  local failed=0
  
  while [[ $completed -lt $total && $iteration -lt $max_iterations ]]; do
    iteration=$((iteration + 1))
    local progress=false
    
    while IFS= read -r step_json; do
      [[ -z "$step_json" ]] && continue
      
      local step_id agent action payload deps
      step_id=$(echo "$step_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
      agent=$(echo "$step_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent','primary-agent'))")
      action=$(echo "$step_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','exec'))")
      payload=$(echo "$step_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('payload',''))")
      deps=$(echo "$step_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('depends',[])))")
      
      # Check current status
      local current_status
      current_status=$("$BB" get "wf:${wf_name}:${step_id}:status" "_global" 2>/dev/null || echo "pending")
      
      [[ "$current_status" == "done" || "$current_status" == "failed" || "$current_status" == "running" ]] && continue
      
      # Check dependencies
      if deps_met "$wf_name" "$deps"; then
        if execute_step "$step_id" "$agent" "$action" "$payload" "$wf_name"; then
          completed=$((completed + 1))
        else
          failed=$((failed + 1))
          completed=$((completed + 1))
        fi
        progress=true
      fi
    done <<< "$steps"
    
    if ! $progress; then
      # No progress made — check if blocked or all done
      if [[ $completed -lt $total ]]; then
        warn "Workflow stalled — ${completed}/${total} completed, possible circular dependency"
        break
      fi
    fi
  done
  
  # Final status
  if [[ $failed -gt 0 ]]; then
    "$BB" set "wf:${wf_name}:status" "partial" "_global" 2>/dev/null
    warn "Workflow ${wf_name}: ${completed}/${total} completed, ${failed} failed"
  elif [[ $completed -eq $total ]]; then
    "$BB" set "wf:${wf_name}:status" "done" "_global" 2>/dev/null
    ok "Workflow ${wf_name}: all ${total} steps completed"
  else
    "$BB" set "wf:${wf_name}:status" "stalled" "_global" 2>/dev/null
    err "Workflow ${wf_name}: stalled at ${completed}/${total}"
  fi
  
  "$BB" set "wf:${wf_name}:completed_at" "$(date '+%Y-%m-%dT%H:%M:%S')" "_global" 2>/dev/null
  "$BB" publish "dag.workflow.completed" "{\"name\":\"$wf_name\",\"completed\":$completed,\"failed\":$failed,\"total\":$total}" "_system" "_all" 2>/dev/null
}

cmd_status() {
  local wf_name="${1:?workflow name required}"
  echo -e "${BLUE}═══ Workflow: ${wf_name} ═══${NC}"
  "$BB" list "_global" 2>/dev/null | grep "wf:${wf_name}" || warn "No data found for workflow: ${wf_name}"
}

cmd_create() {
  local name="${1:?name required}" steps_json="${2:?steps JSON required}"
  ensure_dirs
  local outfile="${WORKFLOWS_DIR}/${name}.json"
  echo "{\"name\":\"${name}\",\"steps\":${steps_json}}" | python3 -m json.tool > "$outfile"
  ok "Workflow created: ${outfile}"
}

cmd_list() {
  ensure_dirs
  echo -e "${BLUE}═══ Saved Workflows ═══${NC}"
  ls -la "$WORKFLOWS_DIR"/*.json 2>/dev/null || warn "No workflows saved yet"
  echo ""
  echo -e "${BLUE}═══ Recent Workflow Events ═══${NC}"
  "$BB" peek 10 2>/dev/null | grep "dag\." || warn "No DAG events"
}

cmd_retry() {
  local wf_name="${1:?workflow name required}"
  local wf_file="${WORKFLOWS_DIR}/${wf_name}.json"
  [[ -f "$wf_file" ]] || { err "Workflow not found: ${wf_file}"; exit 1; }
  
  # Reset failed steps to pending
  sqlite3 "${HOME}/.agent-evolution/blackboard.db" "
    UPDATE state SET value = 'pending'
    WHERE key LIKE 'wf:${wf_name}:%:status' AND value = 'failed';
  " 2>/dev/null
  ok "Reset failed steps, re-running..."
  cmd_run "$wf_file"
}

cmd_cancel() {
  local wf_name="${1:?workflow name required}"
  sqlite3 "${HOME}/.agent-evolution/blackboard.db" "
    UPDATE state SET value = 'cancelled'
    WHERE key LIKE 'wf:${wf_name}:%:status' AND value IN ('pending','blocked');
  " 2>/dev/null
  "$BB" set "wf:${wf_name}:status" "cancelled" "_global" 2>/dev/null
  ok "Workflow ${wf_name} cancelled"
}

cmd_template() {
  cat <<'TMPL'
{
  "name": "example-workflow",
  "steps": [
    {
      "id": "fetch-data",
      "agent": "primary-agent",
      "action": "exec",
      "payload": "curl -s https://api.example.com/data",
      "depends": []
    },
    {
      "id": "analyze",
      "agent": "finance-agent",
      "action": "spawn",
      "payload": "Analyze the fetched market data",
      "depends": ["fetch-data"]
    },
    {
      "id": "tweet-results",
      "agent": "social-agent",
      "action": "exec",
      "payload": "echo 'Tweet: Analysis complete'",
      "depends": ["analyze"]
    },
    {
      "id": "notify",
      "agent": "primary-agent",
      "action": "notify",
      "payload": "Workflow complete: data fetched, analyzed, tweeted",
      "depends": ["tweet-results"]
    }
  ]
}
TMPL
}

# Main
case "${1:---help}" in
  run)      shift; cmd_run "$@" ;;
  status)   shift; cmd_status "$@" ;;
  create)   shift; cmd_create "$@" ;;
  list)     cmd_list ;;
  retry)    shift; cmd_retry "$@" ;;
  cancel)   shift; cmd_cancel "$@" ;;
  template) cmd_template ;;
  --help|-h) show_help ;;
  *)        err "Unknown: $1"; show_help ;;
esac
