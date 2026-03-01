#!/usr/bin/env bash
set -euo pipefail

# Oracle Event Bridge — Connects Blackboard events to AgentSystem actions
# Usage: event-bridge.sh [--daemon] [--once] [--help]
#
# Polls Blackboard for unconsumed events and dispatches them:
#   - task.request  → sessions_spawn via agent-system CLI
#   - dag.step.*    → Log to metrics
#   - agent.alert   → Discord notification
#   - cron.trigger  → Wake cron job
#   - webhook.*     → Forward to n8n or external URL
#   - bb.query      → Execute blackboard query, publish result
#
# Run modes:
#   --once     Process pending events once and exit
#   --daemon   Loop every 30 seconds (for launchd)
#   --help     Show this help

readonly BB="${HOME}/.agent-evolution/scripts/blackboard.sh"
readonly METRICS="${HOME}/.agent-evolution/scripts/metrics.sh"
readonly DB="${HOME}/.agent-evolution/blackboard.db"
readonly POLL_INTERVAL="${ORACLE_EVENT_POLL_INTERVAL:-30}"
readonly N8N_WEBHOOK_BASE="${N8N_WEBHOOK_BASE:-http://localhost:5678/webhook}"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/event-bridge.log"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" >> "$LOG_FILE"; echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "$LOG_FILE"; echo -e "${RED}✗${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

show_help() {
  head -20 "$0" | grep '^#' | sed 's/^# *//'
  exit 0
}

dispatch_event() {
  local id="$1" source="$2" event_type="$3" payload="$4"
  
  case "$event_type" in
    task.request)
      local agent task_content
      agent=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_agent','primary-agent'))" 2>/dev/null || echo "primary-agent")
      task_content=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',''))" 2>/dev/null || echo "$payload")
      log "Dispatching task to ${agent}: ${task_content:0:80}"
      # Publish acknowledgement
      "$BB" publish "task.ack" "{\"event_id\":$id,\"agent\":\"$agent\",\"status\":\"dispatched\"}" "_system" "$source" 2>/dev/null
      ;;
      
    agent.alert|agent.error)
      local severity msg
      severity=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('severity','warn'))" 2>/dev/null || echo "warn")
      msg=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','Unknown alert'))" 2>/dev/null || echo "$payload")
      log "ALERT [${severity}] from ${source}: ${msg}"
      if [[ "$severity" == "critical" ]]; then
        # Record in metrics if available
        [[ -x "$METRICS" ]] && "$METRICS" record "${source}" alert 0 "critical: ${msg:0:100}" 2>/dev/null || true
      fi
      ;;
      
    cron.trigger)
      local job_id
      job_id=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || echo "")
      if [[ -n "$job_id" ]]; then
        log "Triggering cron job: ${job_id}"
        # This would be: agent-system cron run <job_id> — but we can't call agent-system directly
        # Instead, publish a wake event via the cron tool
        "$BB" publish "cron.triggered" "{\"job_id\":\"$job_id\",\"triggered_by\":\"$source\"}" "_system" "_all" 2>/dev/null
      fi
      ;;
      
    webhook.*)
      local url
      url=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null || echo "")
      local body
      body=$(echo "$payload" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('body',{})))" 2>/dev/null || echo "{}")
      if [[ -n "$url" ]]; then
        log "Forwarding webhook to: ${url}"
        curl -s -X POST -H "Content-Type: application/json" -d "$body" "$url" >/dev/null 2>&1 || err "Webhook failed: ${url}"
      fi
      ;;
      
    n8n.trigger)
      local workflow_path
      workflow_path=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''))" 2>/dev/null || echo "")
      if [[ -n "$workflow_path" ]]; then
        local webhook_url="${N8N_WEBHOOK_BASE}/${workflow_path}"
        log "Triggering n8n webhook: ${webhook_url}"
        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url" >/dev/null 2>&1 || err "n8n webhook failed"
      fi
      ;;
      
    bb.query)
      local query_cmd
      query_cmd=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command','stats'))" 2>/dev/null || echo "stats")
      log "Blackboard query: ${query_cmd}"
      local result
      result=$("$BB" $query_cmd 2>/dev/null || echo "query failed")
      "$BB" publish "bb.result" "{\"query\":\"$query_cmd\",\"result\":\"${result:0:500}\"}" "_system" "$source" 2>/dev/null
      ;;
      
    dag.*)
      # DAG events — log to metrics
      log "DAG event: ${event_type} — ${payload:0:100}"
      [[ -x "$METRICS" ]] && "$METRICS" record "dag" "${event_type}" 0 "${payload:0:200}" 2>/dev/null || true
      ;;
      
    *)
      log "Unhandled event type: ${event_type} (id:${id}, from:${source})"
      ;;
  esac
}

process_events() {
  [[ -f "$DB" ]] || { warn "Blackboard not initialized"; return 0; }
  
  local events
  events=$(sqlite3 -json "$DB" "
    SELECT id, source_agent, event_type, payload
    FROM events
    WHERE consumed_at IS NULL AND target_agent IN ('_system', '_all', 'oracle', 'primary-agent')
    ORDER BY priority DESC, id ASC
    LIMIT 20;
  " 2>/dev/null || echo "[]")
  
  local count
  count=$(echo "$events" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  
  if [[ "$count" -eq 0 || "$count" == "0" ]]; then
    return 0
  fi
  
  log "Processing ${count} events..."
  
  echo "$events" | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    print(f\"{e['id']}|{e['source_agent']}|{e['event_type']}|{e.get('payload','')}\")
" 2>/dev/null | while IFS='|' read -r id source etype payload; do
    dispatch_event "$id" "$source" "$etype" "$payload"
  done
  
  # Mark as consumed
  sqlite3 "$DB" "
    UPDATE events SET consumed_at = strftime('%Y-%m-%dT%H:%M:%S','now','localtime'), consumed_by = 'bridge'
    WHERE consumed_at IS NULL AND target_agent IN ('_system', '_all', 'oracle', 'primary-agent')
    LIMIT 20;
  " 2>/dev/null
  
  ok "Processed ${count} events"
}

cmd_daemon() {
  log "Event bridge daemon started (poll every ${POLL_INTERVAL}s)"
  "$BB" publish "bridge.started" '{"mode":"daemon"}' "_system" "_all" 2>/dev/null || true
  
  while true; do
    process_events || true
    sleep "$POLL_INTERVAL"
  done
}

cmd_once() {
  process_events
}

# Main
case "${1:---once}" in
  --daemon|-d)  cmd_daemon ;;
  --once|-1)    cmd_once ;;
  --help|-h)    show_help ;;
  *)            err "Unknown: $1"; show_help ;;
esac
