#!/usr/bin/env bash
# STANDBY: Paralel browser otomasyonu — manual kullanim. Gelecekte otonom tweet pipeline entegrasyonu.
set -euo pipefail

# Oracle Parallel Browser — Multi-profile Chrome CDP + browser-use orchestration
# Usage: parallel-browser.sh <command> [args]
# Commands:
#   profiles                      List available CDP profiles
#   launch <profile> [port]       Launch a CDP Chrome instance
#   kill <profile|port>           Kill a CDP instance
#   status                        Show all running CDP instances
#   run <profile> <script>        Run agent-browser commands on a profile
#   parallel <script1> <script2>  Run scripts on different profiles simultaneously
#   headless <url> [script]       Run browser-use headless session
#   cleanup                       Kill all CDP instances except primary
#   --help                        Show this help
#
# Profiles: primary (18804, login'li), secondary (18805), tertiary (18806)
# Primary profile is the user's logged-in Chrome — NEVER kill it without asking.

readonly CDP_BASE_DIR="${HOME}/Library/Application Support/Google"
readonly PRIMARY_PORT=18804
readonly PRIMARY_PROFILE="Chrome-CDP"
readonly SCRIPT_NAME="$(basename "$0")"

# Profile registry (bash 3 compatible — no associative arrays on macOS default bash)
profile_port() {
  case "$1" in
    primary)  echo 18804 ;;
    secondary) echo 18805 ;;
    tertiary) echo 18806 ;;
    headless) echo 18807 ;;
    *) echo "" ;;
  esac
}

profile_dir() {
  case "$1" in
    primary)  echo "Chrome-CDP" ;;
    secondary) echo "Chrome-CDP-2" ;;
    tertiary) echo "Chrome-CDP-3" ;;
    headless) echo "Chrome-CDP-Headless" ;;
    *) echo "" ;;
  esac
}

ALL_PROFILES="primary secondary tertiary headless"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${BLUE}[BROWSER]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

show_help() {
  head -18 "$0" | grep '^#' | sed 's/^# *//'
  exit 0
}

get_port() {
  profile_port "$1"
}

get_dir() {
  profile_dir "$1"
}

cmd_profiles() {
  echo -e "${BLUE}═══ Available CDP Profiles ═══${NC}"
  for name in $ALL_PROFILES; do
    local port dir running
    port=$(get_port "$name")
    dir=$(get_dir "$name")
    if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      running="${GREEN}RUNNING${NC}"
    else
      running="${RED}STOPPED${NC}"
    fi
    local profile_path="${CDP_BASE_DIR}/${dir}"
    local exists=""
    [[ -d "$profile_path" ]] && exists="[dir exists]" || exists="[will create]"
    printf "  %-12s port:%-5s dir:%-20s %b %s\n" "$name" "$port" "$dir" "$running" "$exists"
  done
}

cmd_launch() {
  local profile="${1:?profile name required}"
  local port dir profile_dir
  
  port=$(get_port "$profile")
  dir=$(get_dir "$profile")
  if [[ -z "$port" ]]; then
    err "Unknown profile: ${profile}. Use: ${ALL_PROFILES}"
    exit 1
  fi
  
  # Check if already running
  if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "Profile ${profile} already running on port ${port}"
    return 0
  fi
  
  profile_dir="${CDP_BASE_DIR}/${dir}"
  
  log "Launching ${profile} on port ${port}..."
  
  if [[ "$profile" == "headless" ]]; then
    # Headless mode
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      --headless=new \
      --remote-debugging-port="$port" \
      --remote-allow-origins=* \
      --user-data-dir="$profile_dir" \
      --no-first-run \
      --no-default-browser-check \
      --disable-gpu \
      --window-size=1920,1080 \
      &>/dev/null &
  else
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      --remote-debugging-port="$port" \
      --remote-allow-origins=* \
      --user-data-dir="$profile_dir" \
      --no-first-run \
      --no-default-browser-check \
      &>/dev/null &
  fi
  
  # Wait for port to be ready
  local tries=0
  while ! lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; do
    sleep 1
    tries=$((tries + 1))
    if [[ $tries -ge 15 ]]; then
      err "Timeout waiting for Chrome on port ${port}"
      return 1
    fi
  done
  
  ok "Profile ${profile} ready on port ${port}"
}

cmd_kill() {
  local target="${1:?profile or port required}"
  local port
  
  port=$(get_port "$target")
  if [[ -n "$port" ]]; then
    if [[ "$target" == "primary" ]]; then
      warn "Killing PRIMARY profile — this is the logged-in Chrome!"
      read -p "Are you sure? (y/N) " -n 1 -r
      echo
      [[ $REPLY =~ ^[Yy]$ ]] || return 0
    fi
  else
    port="$target"
  fi
  
  local pids
  pids=$(lsof -t -i ":${port}" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill 2>/dev/null || true
    ok "Killed process(es) on port ${port}"
  else
    warn "Nothing running on port ${port}"
  fi
}

cmd_status() {
  echo -e "${BLUE}═══ CDP Instance Status ═══${NC}"
  for name in $ALL_PROFILES; do
    local port
    port=$(get_port "$name")
    if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      local pid tabs
      pid=$(lsof -t -i ":${port}" -sTCP:LISTEN 2>/dev/null | head -1)
      tabs=$(curl -s "http://localhost:${port}/json/list" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "?")
      echo -e "  ${GREEN}●${NC} ${name} (port:${port}, pid:${pid}, tabs:${tabs})"
    else
      echo -e "  ${RED}○${NC} ${name} (port:${port})"
    fi
  done
  
  # Also check unknown Chrome debug instances
  local extra
  extra=$(lsof -i -sTCP:LISTEN 2>/dev/null | grep "Google Chrome" | grep -v "18804\|18805\|18806\|18807" || true)
  if [[ -n "$extra" ]]; then
    echo ""
    warn "Unknown Chrome debug ports:"
    echo "$extra"
  fi
}

cmd_run() {
  local profile="${1:?profile required}" script="${2:?script/command required}"
  local port
  port=$(get_port "$profile")
  
  if ! lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    log "Profile ${profile} not running, launching..."
    cmd_launch "$profile"
  fi
  
  # Check if agent-browser is available
  if command -v agent-browser >/dev/null 2>&1; then
    log "Running on ${profile} (port ${port}): ${script}"
    agent-browser connect "$port" -- "$script"
  else
    err "agent-browser not found. Install: brew install anthropic/tap/agent-browser"
    exit 1
  fi
}

cmd_parallel() {
  if [[ $# -lt 2 ]]; then
    err "Need at least 2 profile:command pairs"
    echo "Usage: $SCRIPT_NAME parallel 'primary:snapshot' 'secondary:navigate https://example.com'"
    exit 1
  fi
  
  log "Running ${#} parallel browser tasks..."
  
  local pids=()
  local profiles=()
  
  for pair in "$@"; do
    local profile cmd port
    profile=$(echo "$pair" | cut -d: -f1)
    cmd=$(echo "$pair" | cut -d: -f2-)
    port=$(get_port "$profile")
    
    if ! lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      cmd_launch "$profile"
    fi
    
    (
      log "  [${profile}] Executing: ${cmd}"
      eval "$cmd" 2>&1 | sed "s/^/  [${profile}] /"
    ) &
    pids+=($!)
    profiles+=("$profile")
  done
  
  # Wait for all
  local failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      err "Task on ${profiles[$i]} failed"
      failed=$((failed + 1))
    else
      ok "Task on ${profiles[$i]} completed"
    fi
  done
  
  [[ $failed -eq 0 ]] && ok "All parallel tasks completed" || warn "${failed} task(s) failed"
}

cmd_headless() {
  local url="${1:?URL required}"
  local script="${2:-}"
  
  # Use browser-use Python venv
  local venv="${HOME}/.venv/browser-use"
  if [[ ! -d "$venv" ]]; then
    err "browser-use venv not found at ${venv}"
    exit 1
  fi
  
  if [[ -n "$script" && -f "$script" ]]; then
    log "Running headless browser-use script on ${url}..."
    source "${venv}/bin/activate"
    python3 "$script" "$url"
    deactivate
  else
    # Default: snapshot page
    log "Headless snapshot of ${url}..."
    cmd_launch headless
    local port
    port=$(get_port "headless")
    curl -s "http://localhost:${port}/json/new?${url}" >/dev/null 2>&1
    sleep 3
    if command -v agent-browser >/dev/null 2>&1; then
      agent-browser connect "$port" -- snapshot
    fi
    cmd_kill headless
  fi
}

cmd_cleanup() {
  log "Cleaning up non-primary CDP instances..."
  for name in secondary tertiary headless; do
    local port
    port=$(get_port "$name")
    if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      cmd_kill "$name"
    fi
  done
  ok "Cleanup done. Primary (${PRIMARY_PORT}) untouched."
}

# Main
case "${1:---help}" in
  profiles)  cmd_profiles ;;
  launch)    shift; cmd_launch "$@" ;;
  kill)      shift; cmd_kill "$@" ;;
  status)    cmd_status ;;
  run)       shift; cmd_run "$@" ;;
  parallel)  shift; cmd_parallel "$@" ;;
  headless)  shift; cmd_headless "$@" ;;
  cleanup)   cmd_cleanup ;;
  --help|-h) show_help ;;
  *)         err "Unknown: $1"; show_help ;;
esac
