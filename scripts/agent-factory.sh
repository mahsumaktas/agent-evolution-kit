#!/usr/bin/env bash
# STANDBY: Agent yaratma/klonlama — manual kullanim. Gelecekte agent-mesh entegrasyonu.
set -euo pipefail

# Oracle Agent Factory — Dynamic agent creation via config.patch
# Usage: agent-factory.sh <command> [args]
# Commands:
#   create <name> <desc> [model]   Create a new agent (config + workspace)
#   template <name>                Create agent workspace with SOUL.md template
#   list                           List all configured agents
#   disable <name>                 Disable an agent (remove from config)
#   enable <name> [model]          Re-enable a disabled agent
#   status                         Show agent health from blackboard
#   workspace <name>               Show/create agent workspace path
#   --help                         Show this help
#
# Creates agent config, workspace dir, and basic SOUL.md.
# Uses gateway config.patch for runtime agent creation (hot-reload).
# Agents are ephemeral workers — create for a task, disable when done.

readonly WORKSPACE_BASE="${HOME}/.agent-evolution/team"
readonly CONFIG_PATH="${HOME}/.agent-evolution/agent-system.json"
readonly BB="${HOME}/.agent-evolution/scripts/blackboard.sh"
readonly SCRIPT_NAME="$(basename "$0")"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${BLUE}[FACTORY]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

show_help() {
  head -18 "$0" | grep '^#' | sed 's/^# *//'
  exit 0
}

cmd_create() {
  local name="${1:?agent name required}"
  local desc="${2:?description required}"
  local model="${3:-anthropic/claude-sonnet-4-6}"
  local disallowed_tools="${4:-}"  # Comma-separated list e.g. "web_search,web_fetch"
  
  # Validate name (lowercase, alphanumeric + hyphen)
  if ! echo "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
    err "Invalid agent name: ${name} (use lowercase, alphanumeric, hyphens)"
    exit 1
  fi
  
  # Check if already exists
  if python3 -c "
import json
cfg = json.load(open('${CONFIG_PATH}'))
agents = cfg.get('agents', {})
if '${name}' in agents:
    exit(0)
exit(1)
" 2>/dev/null; then
    warn "Agent '${name}' already exists in config"
    return 0
  fi
  
  # Create workspace
  local ws="${WORKSPACE_BASE}/${name}"
  mkdir -p "$ws"
  
  # Create minimal SOUL.md
  cat > "${ws}/SOUL.md" << SOUL
# ${name} — Oracle Network Worker

## Kimlik
**${name}** — ${desc}
Oracle ağının bir parçası. Görev odaklı, verimli, kısa cevaplar.

## Kurallar
- Türkçe tercih, İngilizce de OK
- Kısa ve keskin cevaplar
- Görevini tamamla, raporla
- Önemli bilgiyi hemen diske yaz
- Oracle'a (primary-agent) sonuç bildir

## Yetkinlikler
${desc}

*Oracle Network — ${name} operational.* 🦉
SOUL

  # Create BOOTSTRAP.md
  cat > "${ws}/BOOTSTRAP.md" << BOOT
# ${name} — Bootstrap
1. SOUL.md oku
2. Görevini anla
3. Uygula
BOOT

  log "Workspace created: ${ws}"
  
  # Build config patch — we need to construct the agents section
  # This is tricky because config.patch merges, so we need the agent definition
  log "Creating agent config for '${name}'..."
  
  # Generate the config patch JSON
  local patch_json
  patch_json=$(python3 -c "
import json
agent_cfg = {
    'label': '${name}',
    'model': '${model}',
    'cwd': '${ws}'
}
# Add disallowed_tools if specified (DeerFlow pattern)
disallowed = '${disallowed_tools}'
if disallowed:
    agent_cfg['disallowedTools'] = [t.strip() for t in disallowed.split(',') if t.strip()]
patch = {'agents': {'${name}': agent_cfg}}
print(json.dumps(patch))
")
  
  echo "$patch_json" > "/tmp/agent-factory-${name}.json"
  log "Config patch ready: /tmp/agent-factory-${name}.json"
  log "Patch content: ${patch_json}"
  
  echo ""
  echo -e "${YELLOW}═══ NEXT STEP ═══${NC}"
  echo "Apply config patch via AgentSystem gateway tool:"
  echo "  gateway config.patch with raw='${patch_json}'"
  echo ""
  echo "Or manually: agent-system config patch < /tmp/agent-factory-${name}.json"
  echo ""
  
  # Record in blackboard
  [[ -x "$BB" ]] && "$BB" publish "agent.created" "{\"name\":\"${name}\",\"model\":\"${model}\",\"desc\":\"${desc}\"}" "_system" "_all" 2>/dev/null || true
  
  ok "Agent '${name}' factory setup complete. Apply config.patch to activate."
}

cmd_template() {
  local name="${1:?agent name required}"
  local ws="${WORKSPACE_BASE}/${name}"
  mkdir -p "$ws"
  
  if [[ -f "${ws}/SOUL.md" ]]; then
    warn "SOUL.md already exists at ${ws}/SOUL.md"
  else
    cat > "${ws}/SOUL.md" << 'TMPL'
# AGENT_NAME — Oracle Network Worker

## Kimlik
Görev odaklı worker. Oracle ağının parçası.

## Kurallar  
- Türkçe tercih
- Kısa cevaplar
- Görev tamamla, raporla
- Önemli bilgiyi diske yaz

## Yetkinlikler
[Buraya agent yetkinlikleri yazılacak]
TMPL
    ok "Template created: ${ws}/SOUL.md"
  fi
}

cmd_list() {
  echo -e "${BLUE}═══ Configured Agents ═══${NC}"
  python3 -c "
import json
cfg = json.load(open('${CONFIG_PATH}'))
agents = cfg.get('agents', {})
# agents.list is the array of agent configs
agent_list = agents.get('list', [])
if not agent_list:
    print('  No agents in list')
for a in agent_list:
    name = a.get('id', a.get('name', '?'))
    model_obj = a.get('model', {})
    model = model_obj.get('primary', '?') if isinstance(model_obj, dict) else str(model_obj)
    ws = a.get('workspace', a.get('cwd', '?'))
    label = a.get('name', name)
    print(f'  {name:20s} ({label:15s}) model:{model:40s} ws:{ws}')
" 2>/dev/null || err "Failed to parse config"
}

cmd_disable() {
  local name="${1:?agent name required}"
  warn "Disabling agent '${name}' requires removing from config."
  echo "Use: gateway config.patch to remove the agent entry"
  echo "Or: Manually edit ~/.agent-evolution/agent-system.json"
  echo ""
  echo "Note: This won't delete the workspace. Files remain at: ${WORKSPACE_BASE}/${name}/"
}

cmd_enable() {
  local name="${1:?agent name required}"
  local model="${2:-anthropic/claude-sonnet-4-6}"
  local ws="${WORKSPACE_BASE}/${name}"
  
  if [[ ! -d "$ws" ]]; then
    err "Workspace not found: ${ws}. Use 'create' first."
    exit 1
  fi
  
  cmd_create "$name" "Re-enabled agent" "$model"
}

cmd_status() {
  echo -e "${BLUE}═══ Agent Status (Blackboard) ═══${NC}"
  [[ -x "$BB" ]] && "$BB" list 2>/dev/null | grep -E "^(primary-agent|social-agent|finance-agent|analytics-agent|assistant-agent|hachi-)" || warn "No agent state in blackboard"
}

cmd_workspace() {
  local name="${1:?agent name required}"
  local ws="${WORKSPACE_BASE}/${name}"
  if [[ -d "$ws" ]]; then
    echo "$ws"
    ls -la "$ws"
  else
    mkdir -p "$ws"
    ok "Created workspace: ${ws}"
  fi
}

# Main
case "${1:---help}" in
  create)    shift; cmd_create "$@" ;;
  template)  shift; cmd_template "$@" ;;
  list)      cmd_list ;;
  disable)   shift; cmd_disable "$@" ;;
  enable)    shift; cmd_enable "$@" ;;
  status)    cmd_status ;;
  workspace) shift; cmd_workspace "$@" ;;
  --help|-h) show_help ;;
  *)         err "Unknown: $1"; show_help ;;
esac
