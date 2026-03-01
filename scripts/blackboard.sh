#!/usr/bin/env bash
set -euo pipefail

# Oracle Shared Blackboard — SQLite-backed inter-agent state + event queue
# Usage: blackboard.sh <command> [args]
# Commands:
#   init                          Create/upgrade database schema
#   set <key> <value> [agent]     Set a key-value pair
#   get <key> [agent]             Get a value (agent="" for global)
#   delete <key> [agent]          Delete a key
#   list [agent]                  List all keys (optionally filtered by agent)
#   publish <type> <payload> [source] [target]   Publish event
#   consume [target] [limit]      Consume unconsumed events for target agent
#   peek [limit]                  Peek at recent events without consuming
#   task-add <agent> <payload> [parent_id] [depends_on]  Add task
#   task-update <id> <status>     Update task status (pending/running/done/failed)
#   task-list [agent] [status]    List tasks
#   task-deps <id>                Check if dependencies are met
#   stats                         Show database statistics
#   gc [days]                     Garbage collect old consumed events (default: 7)
#   --help                        Show this help

readonly DB="${ORACLE_BLACKBOARD_DB:-${HOME}/.agent-evolution/blackboard.db}"
readonly SCRIPT_NAME="$(basename "$0")"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

show_help() {
  head -20 "$0" | grep '^#' | sed 's/^# *//'
  exit 0
}

ensure_db() {
  local dir
  dir="$(dirname "$DB")"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  
  sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS state (
  agent_id TEXT NOT NULL DEFAULT '_global',
  key TEXT NOT NULL,
  value TEXT,
  type TEXT DEFAULT 'string',
  updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
  PRIMARY KEY (agent_id, key)
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_agent TEXT NOT NULL DEFAULT '_system',
  target_agent TEXT DEFAULT '_all',
  event_type TEXT NOT NULL,
  payload TEXT,
  priority INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
  consumed_at TEXT,
  consumed_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_target ON events(target_agent, consumed_at);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);

CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id INTEGER REFERENCES tasks(id),
  agent_id TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK(status IN ('pending','running','done','failed','blocked')),
  priority INTEGER DEFAULT 0,
  payload TEXT NOT NULL,
  result TEXT,
  depends_on TEXT,
  created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now','localtime')),
  started_at TEXT,
  completed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_agent ON tasks(agent_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
SQL
}

cmd_set() {
  local key="${1:?key required}" value="${2:?value required}" agent="${3:-_global}"
  ensure_db
  sqlite3 "$DB" "INSERT OR REPLACE INTO state(agent_id, key, value, updated_at) VALUES('$agent', '$key', '$value', strftime('%Y-%m-%dT%H:%M:%S','now','localtime'));"
  ok "Set ${agent}/${key} = ${value}"
}

cmd_get() {
  local key="${1:?key required}" agent="${2:-_global}"
  ensure_db
  local result
  result=$(sqlite3 "$DB" "SELECT value FROM state WHERE agent_id='$agent' AND key='$key';")
  if [[ -n "$result" ]]; then
    echo "$result"
  else
    err "Key not found: ${agent}/${key}"
    return 1
  fi
}

cmd_delete() {
  local key="${1:?key required}" agent="${2:-_global}"
  ensure_db
  sqlite3 "$DB" "DELETE FROM state WHERE agent_id='$agent' AND key='$key';"
  ok "Deleted ${agent}/${key}"
}

cmd_list() {
  local agent="${1:-}"
  ensure_db
  if [[ -n "$agent" ]]; then
    sqlite3 -header -column "$DB" "SELECT agent_id, key, value, updated_at FROM state WHERE agent_id='$agent' ORDER BY key;"
  else
    sqlite3 -header -column "$DB" "SELECT agent_id, key, value, updated_at FROM state ORDER BY agent_id, key;"
  fi
}

cmd_publish() {
  local event_type="${1:?event_type required}" payload="${2:?payload required}"
  local source="${3:-_system}" target="${4:-_all}" priority="${5:-0}" trace_id="${6:-}"
  ensure_db
  if [[ -z "$trace_id" ]]; then
    trace_id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
  fi
  local id
  id=$(sqlite3 "$DB" "INSERT INTO events(source_agent, target_agent, event_type, payload, priority, trace_id) VALUES('$source', '$target', '$event_type', '$payload', $priority, '$trace_id') RETURNING id;")
  ok "Published event #${id}: ${event_type} (${source} → ${target}) [trace=${trace_id}]"
  echo "$id"
}

cmd_consume() {
  local target="${1:-_all}" limit="${2:-10}"
  ensure_db
  # Get events for this target (or _all) that haven't been consumed
  sqlite3 -json "$DB" "
    SELECT id, source_agent, event_type, payload, priority, created_at
    FROM events
    WHERE consumed_at IS NULL
      AND (target_agent = '$target' OR target_agent = '_all')
    ORDER BY priority DESC, id ASC
    LIMIT $limit;
  "
  # Mark as consumed
  sqlite3 "$DB" "
    UPDATE events SET consumed_at = strftime('%Y-%m-%dT%H:%M:%S','now','localtime'), consumed_by = '$target'
    WHERE consumed_at IS NULL
      AND (target_agent = '$target' OR target_agent = '_all')
    LIMIT $limit;
  "
}

cmd_peek() {
  local limit="${1:-20}"
  ensure_db
  sqlite3 -header -column "$DB" "
    SELECT id, source_agent, target_agent, event_type, 
           substr(payload,1,60) as payload_preview,
           CASE WHEN consumed_at IS NULL THEN '⏳' ELSE '✓' END as status,
           created_at
    FROM events
    ORDER BY id DESC
    LIMIT $limit;
  "
}

cmd_task_add() {
  local agent="${1:?agent required}" payload="${2:?payload required}"
  local parent_id="${3:-}" depends_on="${4:-}" trace_id="${5:-}"
  ensure_db
  # Auto-generate trace_id if not provided
  if [[ -z "$trace_id" ]]; then
    trace_id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
  fi
  local sql="INSERT INTO tasks(agent_id, payload, trace_id"
  local vals="VALUES('$agent', '$payload', '$trace_id'"
  if [[ -n "$parent_id" ]]; then
    sql+=", parent_id"
    vals+=", $parent_id"
  fi
  if [[ -n "$depends_on" ]]; then
    sql+=", depends_on, status"
    vals+=", '$depends_on', 'blocked'"
  fi
  sql+=") $vals) RETURNING id;"
  local id
  id=$(sqlite3 "$DB" "$sql")
  ok "Task #${id} created for ${agent} [trace=${trace_id}]"
  echo "$id"
}

cmd_task_update() {
  local id="${1:?task id required}" status="${2:?status required}"
  ensure_db
  local extra=""
  case "$status" in
    running) extra=", started_at = strftime('%Y-%m-%dT%H:%M:%S','now','localtime')" ;;
    done|failed) extra=", completed_at = strftime('%Y-%m-%dT%H:%M:%S','now','localtime')" ;;
  esac
  sqlite3 "$DB" "UPDATE tasks SET status = '$status' $extra WHERE id = $id;"
  ok "Task #${id} → ${status}"
  
  # Auto-unblock dependents
  if [[ "$status" == "done" ]]; then
    sqlite3 "$DB" "
      UPDATE tasks SET status = 'pending'
      WHERE status = 'blocked'
        AND depends_on LIKE '%$id%'
        AND NOT EXISTS (
          SELECT 1 FROM tasks t2
          WHERE tasks.depends_on LIKE '%' || t2.id || '%'
            AND t2.status NOT IN ('done')
            AND t2.id != $id
        );
    "
  fi
}

cmd_task_list() {
  local agent="${1:-}" status="${2:-}"
  ensure_db
  local where="1=1"
  [[ -n "$agent" ]] && where+=" AND agent_id='$agent'"
  [[ -n "$status" ]] && where+=" AND status='$status'"
  sqlite3 -header -column "$DB" "
    SELECT id, agent_id, status, priority, substr(payload,1,50) as payload_preview, 
           depends_on, created_at, completed_at
    FROM tasks WHERE $where ORDER BY priority DESC, id DESC LIMIT 50;
  "
}

cmd_task_deps() {
  local id="${1:?task id required}"
  ensure_db
  local deps
  deps=$(sqlite3 "$DB" "SELECT depends_on FROM tasks WHERE id = $id;")
  if [[ -z "$deps" ]]; then
    ok "Task #${id} has no dependencies"
    return 0
  fi
  echo "Dependencies for task #${id}: $deps"
  # Check each dependency
  local all_met=true
  for dep_id in $(echo "$deps" | tr ',' ' '); do
    local dep_status
    dep_status=$(sqlite3 "$DB" "SELECT status FROM tasks WHERE id = $dep_id;")
    if [[ "$dep_status" == "done" ]]; then
      ok "  #${dep_id}: done ✓"
    else
      warn "  #${dep_id}: ${dep_status:-not found} ✗"
      all_met=false
    fi
  done
  $all_met && ok "All dependencies met!" || warn "Blocked — not all deps done"
}

cmd_stats() {
  ensure_db
  echo -e "${BLUE}═══ Blackboard Stats ═══${NC}"
  echo -n "State entries: "
  sqlite3 "$DB" "SELECT COUNT(*) FROM state;"
  echo -n "Events (total/unconsumed): "
  sqlite3 "$DB" "SELECT COUNT(*) || ' / ' || SUM(CASE WHEN consumed_at IS NULL THEN 1 ELSE 0 END) FROM events;"
  echo -n "Tasks (total/pending/running/done/failed): "
  sqlite3 "$DB" "SELECT COUNT(*) || ' / ' || SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) || ' / ' || SUM(CASE WHEN status='running' THEN 1 ELSE 0 END) || ' / ' || SUM(CASE WHEN status='done' THEN 1 ELSE 0 END) || ' / ' || SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) FROM tasks;"
  echo ""
  echo -e "${BLUE}Events by type:${NC}"
  sqlite3 -header -column "$DB" "SELECT event_type, COUNT(*) as count FROM events GROUP BY event_type ORDER BY count DESC LIMIT 10;"
  echo ""
  echo -e "${BLUE}State by agent:${NC}"
  sqlite3 -header -column "$DB" "SELECT agent_id, COUNT(*) as keys FROM state GROUP BY agent_id;"
}

cmd_gc() {
  local days="${1:-7}"
  ensure_db
  local deleted
  deleted=$(sqlite3 "$DB" "DELETE FROM events WHERE consumed_at IS NOT NULL AND created_at < strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime', '-$days days') RETURNING id;" | wc -l | tr -d ' ')
  ok "Garbage collected ${deleted} consumed events older than ${days} days"
}

cmd_init() {
  ensure_db
  ok "Blackboard initialized at ${DB}"
  cmd_stats
}

# Main dispatch
case "${1:---help}" in
  init)       cmd_init ;;
  set)        shift; cmd_set "$@" ;;
  get)        shift; cmd_get "$@" ;;
  delete)     shift; cmd_delete "$@" ;;
  list)       shift; cmd_list "$@" ;;
  publish)    shift; cmd_publish "$@" ;;
  consume)    shift; cmd_consume "$@" ;;
  peek)       shift; cmd_peek "$@" ;;
  task-add)   shift; cmd_task_add "$@" ;;
  task-update) shift; cmd_task_update "$@" ;;
  task-list)  shift; cmd_task_list "$@" ;;
  task-deps)  shift; cmd_task_deps "$@" ;;
  stats)      cmd_stats ;;
  gc)         shift; cmd_gc "$@" ;;
  --help|-h)  show_help ;;
  *)          err "Unknown command: $1"; show_help ;;
esac
