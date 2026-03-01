#!/usr/bin/env bash
set -euo pipefail

# governance.sh — Agent Governance Enforcement Engine
# Policy: ~/.agent-evolution/config/governance.yaml
# Audit: ~/.agent-evolution/governance/audit.db
# Trust: ~/.agent-evolution/governance/trust-scores.json

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICY_FILE="$HOME/clawd/config/governance.yaml"
AUTONOMY_FILE="$HOME/clawd/config/autonomy-levels.yaml"
AUDIT_DB="$HOME/.agent-system/governance/audit.db"
TRUST_FILE="$HOME/.agent-system/governance/trust-scores.json"
GOV_DIR="$HOME/.agent-system/governance"

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------------------------------------------------------
# Yardimci fonksiyonlar
# -------------------------------------------------------------------

ensure_dirs() {
  mkdir -p "$GOV_DIR"
}

ensure_db() {
  ensure_dirs
  if [[ ! -f "$AUDIT_DB" ]]; then
    sqlite3 "$AUDIT_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT DEFAULT (datetime('now','localtime')),
  agent TEXT NOT NULL,
  action TEXT NOT NULL,
  args TEXT,
  result TEXT NOT NULL,  -- ALLOW, DENY, WARN
  reason TEXT,
  trust_level INTEGER
);

CREATE TABLE IF NOT EXISTS rate_counters (
  agent TEXT NOT NULL,
  action_type TEXT NOT NULL,
  hour TEXT NOT NULL,
  count INTEGER DEFAULT 0,
  PRIMARY KEY (agent, action_type, hour)
);

CREATE INDEX IF NOT EXISTS idx_audit_agent ON audit_log(agent);
CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_rate_hour ON rate_counters(hour);
SQL
  fi
}

ensure_trust() {
  ensure_dirs
  if [[ ! -f "$TRUST_FILE" ]]; then
    cat > "$TRUST_FILE" <<'JSON'
{
  "primary-agent": 1000,
  "social-agent": 700,
  "finance-agent": 700,
  "analytics-agent": 600,
  "assistant-agent": 500,
  "_default": 500,
  "_last_updated": ""
}
JSON
  fi
}

# YAML parser (basit — yq yoksa grep/awk ile)
yaml_get() {
  local file="$1" key="$2"
  if command -v yq &>/dev/null; then
    yq eval "$key" "$file" 2>/dev/null
  else
    # Fallback: basit grep
    grep -E "^\s+${key}:" "$file" 2>/dev/null | head -1 | awk -F': ' '{print $2}' | tr -d '"' || echo ""
  fi
}

get_mode() {
  if command -v yq &>/dev/null; then
    yq eval '.audit.mode' "$POLICY_FILE" 2>/dev/null || echo "audit-only"
  else
    grep 'mode:' "$POLICY_FILE" | tail -1 | awk '{print $2}' | tr -d '"' || echo "audit-only"
  fi
}

# Autonomy level kontrolu — YAML'i Python ile parse eder
# Kullanim: get_autonomy_level <trust_level> <action>
# Cikti: "ALLOWED L3_self_monitoring" veya "BLOCKED L2_scheduled"
get_autonomy_level() {
  local trust_level="$1" action="${2:-}"
  python3 - "$AUTONOMY_FILE" "$trust_level" "$action" << 'PYEOF'
import sys, re

config_file = sys.argv[1]
trust_level = int(sys.argv[2])
action = sys.argv[3] if len(sys.argv) > 3 else ""

try:
    with open(config_file) as f:
        lines = f.readlines()
except FileNotFoundError:
    print("ALLOWED UNKNOWN")
    sys.exit(0)

# Parse levels
levels = {}
current_level = None

for line in lines:
    # Level header: "  L1_reactive:" pattern
    m = re.match(r'^\s{2}(L\d_\w+):\s*$', line)
    if m:
        current_level = m.group(1)
        levels[current_level] = {"trust_min": 0, "trust_max": 9999, "blocked_actions": []}
        continue

    if current_level is None:
        continue

    # trust_min
    m = re.match(r'^\s+trust_min:\s*(\d+)', line)
    if m:
        levels[current_level]["trust_min"] = int(m.group(1))
        continue

    # trust_max
    m = re.match(r'^\s+trust_max:\s*(\d+)', line)
    if m:
        levels[current_level]["trust_max"] = int(m.group(1))
        continue

    # blocked_actions: [a, b, c]
    m = re.match(r'^\s+blocked_actions:\s*\[([^\]]*)\]', line)
    if m:
        raw = m.group(1).strip()
        if raw:
            levels[current_level]["blocked_actions"] = [x.strip() for x in raw.split(",")]
        continue

# Find matching level for trust
matched_level = None
for name, props in levels.items():
    if props["trust_min"] <= trust_level <= props["trust_max"]:
        matched_level = name
        break

if matched_level is None:
    print("ALLOWED UNKNOWN")
    sys.exit(0)

# If no action to check, just return the level
if not action:
    print(f"ALLOWED {matched_level}")
    sys.exit(0)

# Check if action is blocked
blocked = levels[matched_level]["blocked_actions"]
if action in blocked:
    print(f"BLOCKED {matched_level}")
else:
    print(f"ALLOWED {matched_level}")
PYEOF
}

get_trust_level() {
  local agent="$1"
  if [[ -f "$TRUST_FILE" ]]; then
    local val
    val=$(python3 -c "
import json
with open('$TRUST_FILE') as f:
    d = json.load(f)
print(d.get('$agent', d.get('_default', 500)))
" 2>/dev/null)
    echo "${val:-500}"
  else
    echo "500"
  fi
}

log_audit() {
  local agent="$1" action="$2" args="$3" result="$4" reason="$5"
  local trust
  trust=$(get_trust_level "$agent")
  ensure_db
  sqlite3 "$AUDIT_DB" "INSERT INTO audit_log (agent, action, args, result, reason, trust_level) VALUES ('$agent', '$action', '$(echo "$args" | sed "s/'/''/g")', '$result', '$(echo "$reason" | sed "s/'/''/g")', $trust);"
}

increment_rate() {
  local agent="$1" action_type="$2"
  local hour
  hour=$(date '+%Y-%m-%d-%H')
  ensure_db
  sqlite3 "$AUDIT_DB" "INSERT INTO rate_counters (agent, action_type, hour, count) VALUES ('$agent', '$action_type', '$hour', 1) ON CONFLICT(agent, action_type, hour) DO UPDATE SET count = count + 1;"
}

get_rate_count() {
  local agent="$1" action_type="$2"
  local hour
  hour=$(date '+%Y-%m-%d-%H')
  ensure_db
  sqlite3 "$AUDIT_DB" "SELECT COALESCE(count, 0) FROM rate_counters WHERE agent='$agent' AND action_type='$action_type' AND hour='$hour';" 2>/dev/null || echo "0"
}

# -------------------------------------------------------------------
# check komutu
# -------------------------------------------------------------------

cmd_check() {
  local agent="${1:-}" action="${2:-}" args="${3:-}"

  if [[ -z "$agent" || -z "$action" ]]; then
    echo -e "${RED}Kullanim: governance.sh check <agent> <action> [args]${NC}"
    exit 1
  fi

  local result="ALLOW"
  local reason=""
  local mode
  mode=$(get_mode)

  # 1. Filesystem kontrolu
  if [[ "$action" == "exec" && -n "$args" ]]; then
    # Denied filesystem kontrolu
    local denied_paths=(".ssh" ".aws" ".gnupg")

    # Agent-spesifik denied path'leri kontrol et
    for dp in "${denied_paths[@]}"; do
      if echo "$args" | grep -qE "(~/|/Users/[^/]+/)\.?${dp}" 2>/dev/null; then
        result="DENY"
        reason="Filesystem denied: $dp erisimi yasakli"
        break
      fi
    done
  fi

  # 2. Sensitive action kontrolu
  if [[ "$action" == "exec" && -n "$args" ]]; then
    local destructive_patterns=("rm -rf" "rm -r " "git push --force" "git reset --hard" "drop table" "truncate")
    for pat in "${destructive_patterns[@]}"; do
      if echo "$args" | grep -qi "$pat" 2>/dev/null; then
        if [[ "$result" != "DENY" ]]; then
          result="WARN"
          reason="Destructive action detected: $pat"
        fi
        break
      fi
    done

    local financial_patterns=("trade " "transfer " "payment " "billing ")
    for pat in "${financial_patterns[@]}"; do
      if echo "$args" | grep -qi "$pat" 2>/dev/null; then
        result="DENY"
        reason="Financial action detected: $pat"
        break
      fi
    done
  fi

  # 3. Autonomy level kontrolu
  local trust
  trust=$(get_trust_level "$agent")

  if [[ -f "$AUTONOMY_FILE" ]]; then
    local autonomy_result autonomy_verdict autonomy_level_name
    autonomy_result=$(get_autonomy_level "$trust" "$action")
    autonomy_verdict=$(echo "$autonomy_result" | awk '{print $1}')
    autonomy_level_name=$(echo "$autonomy_result" | awk '{print $2}')

    if [[ "$autonomy_verdict" == "BLOCKED" ]]; then
      result="DENY"
      reason="autonomy_level=$autonomy_level_name"
      log_audit "$agent" "$action" "$args" "$result" "$reason"
      echo -e "${RED}DENY${NC} [$agent] $action ${args:+\"$args\"}"
      echo -e "  Neden: Autonomy level $autonomy_level_name bu aksiyonu engelliyor"
      if [[ "$mode" == "blocking" ]]; then
        exit 1
      else
        echo -e "  ${YELLOW}Audit-only: islem devam eder (normalde engellenirdi)${NC}"
      fi
      return
    else
      echo -e "${BLUE}INFO${NC} [$agent] Autonomy: $autonomy_level_name (trust=$trust)" >&2
    fi
  fi

  # 4. Rate limit kontrolu
  local current_rate action_type="exec"
  current_rate=$(get_rate_count "$agent" "$action_type")
  # Default limit: 30/hour
  local limit=30
  if (( trust >= 1000 )); then limit=100;
  elif (( trust >= 700 )); then limit=50;
  elif (( trust >= 600 )); then limit=40;
  fi

  if (( current_rate >= limit )); then
    if [[ "$result" == "ALLOW" ]]; then
      result="WARN"
      reason="Rate limit: $action_type $current_rate/$limit per hour"
    fi
  fi

  # Rate counter artir
  increment_rate "$agent" "$action_type"

  # Audit log
  log_audit "$agent" "$action" "$args" "$result" "$reason"

  # Sonuc
  case "$result" in
    ALLOW)
      echo -e "${GREEN}ALLOW${NC} [$agent] $action ${args:+\"$args\"}"
      ;;
    WARN)
      echo -e "${YELLOW}WARN${NC} [$agent] $action ${args:+\"$args\"}"
      echo -e "  Neden: $reason"
      if [[ "$mode" == "blocking" ]]; then
        echo -e "  ${RED}BLOCKED (blocking mode)${NC}"
        exit 1
      else
        echo -e "  ${YELLOW}Audit-only: islem devam eder${NC}"
      fi
      ;;
    DENY)
      echo -e "${RED}DENY${NC} [$agent] $action ${args:+\"$args\"}"
      echo -e "  Neden: $reason"
      if [[ "$mode" == "blocking" ]]; then
        exit 1
      else
        echo -e "  ${YELLOW}Audit-only: islem devam eder (normalde engellenirdi)${NC}"
      fi
      ;;
  esac
}

# -------------------------------------------------------------------
# audit komutu
# -------------------------------------------------------------------

cmd_audit() {
  ensure_db
  local agent="" last=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last) last="$2"; shift 2 ;;
      *) agent="$1"; shift ;;
    esac
  done

  echo -e "${BLUE}=== Governance Audit Log ===${NC}"
  echo ""

  local query="SELECT timestamp, agent, action, substr(args,1,50), result, reason FROM audit_log"
  if [[ -n "$agent" ]]; then
    query+=" WHERE agent='$agent'"
  fi
  query+=" ORDER BY id DESC LIMIT $last"

  sqlite3 -header -column "$AUDIT_DB" "$query" 2>/dev/null || echo "(henuz kayit yok)"
}

# -------------------------------------------------------------------
# report komutu
# -------------------------------------------------------------------

cmd_report() {
  ensure_db
  local weekly=false
  [[ "${1:-}" == "--weekly" ]] && weekly=true

  echo -e "${BLUE}=== Governance Raporu ===${NC}"
  echo ""

  # Genel istatistikler
  local period_filter=""
  if $weekly; then
    period_filter="WHERE timestamp >= datetime('now', '-7 days', 'localtime')"
    echo "Donem: Son 7 gun"
  else
    echo "Donem: Tum zamanlar"
  fi
  echo ""

  echo "--- Agent Bazli Islem Sayilari ---"
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT agent, result, COUNT(*) as sayi FROM audit_log $period_filter GROUP BY agent, result ORDER BY agent, result;" \
    2>/dev/null || echo "(veri yok)"

  echo ""
  echo "--- Sonuc Dagilimi ---"
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT result, COUNT(*) as sayi FROM audit_log $period_filter GROUP BY result;" \
    2>/dev/null || echo "(veri yok)"

  echo ""
  echo "--- DENY/WARN Detaylari ---"
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT timestamp, agent, action, reason FROM audit_log $period_filter AND result IN ('DENY','WARN') ORDER BY timestamp DESC LIMIT 20;" \
    2>/dev/null || echo "(ihlal yok)"

  echo ""
  echo "--- Rate Limit Durumlari (bu saat) ---"
  local current_hour
  current_hour=$(date '+%Y-%m-%d-%H')
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT agent, action_type, count FROM rate_counters WHERE hour='$current_hour' ORDER BY count DESC;" \
    2>/dev/null || echo "(veri yok)"
}

# -------------------------------------------------------------------
# trust komutu
# -------------------------------------------------------------------

cmd_trust() {
  ensure_trust
  local agent="${1:-}"
  local change="${2:-}"

  if [[ -z "$agent" ]]; then
    echo -e "${BLUE}=== Trust Scores ===${NC}"
    python3 -c "
import json
with open('$TRUST_FILE') as f:
    d = json.load(f)
for k, v in sorted(d.items()):
    if k.startswith('_'): continue
    print(f'  {k}: {v}')
"
    return
  fi

  if [[ -z "$change" ]]; then
    local score
    score=$(get_trust_level "$agent")
    echo -e "[$agent] Trust: $score"
    return
  fi

  python3 -c "
import json, sys
with open('$TRUST_FILE') as f:
    d = json.load(f)

agent = '$agent'
change = '$change'
current = d.get(agent, d.get('_default', 500))

if change.startswith('+'):
    new = min(1000, current + int(change[1:]))
elif change.startswith('-'):
    new = max(0, current - int(change[1:]))
elif change.startswith('='):
    new = max(0, min(1000, int(change[1:])))
else:
    print('Gecersiz format. Kullanim: +N, -N, =N')
    sys.exit(1)

d[agent] = new
from datetime import datetime
d['_last_updated'] = datetime.now().isoformat()

with open('$TRUST_FILE', 'w') as f:
    json.dump(d, f, indent=2)

print(f'[{agent}] Trust: {current} -> {new}')
"
  log_audit "$agent" "trust_change" "$change" "ALLOW" "Trust updated"
}

# -------------------------------------------------------------------
# autonomy komutu
# -------------------------------------------------------------------

cmd_autonomy() {
  local agent="${1:-}"

  if [[ -z "$agent" ]]; then
    echo -e "${RED}Kullanim: governance.sh autonomy <agent>${NC}"
    exit 1
  fi

  ensure_trust

  if [[ ! -f "$AUTONOMY_FILE" ]]; then
    echo -e "${RED}Hata: $AUTONOMY_FILE bulunamadi${NC}"
    exit 1
  fi

  local trust
  trust=$(get_trust_level "$agent")

  local autonomy_result autonomy_level_name
  autonomy_result=$(get_autonomy_level "$trust" "")
  autonomy_level_name=$(echo "$autonomy_result" | awk '{print $2}')

  echo -e "${BLUE}=== Autonomy Level ===${NC}"
  echo -e "  Agent:   $agent"
  echo -e "  Trust:   $trust"
  echo -e "  Level:   ${GREEN}$autonomy_level_name${NC}"

  # Blocked actions listesi
  local blocked
  blocked=$(python3 - "$AUTONOMY_FILE" "$trust" << 'PYEOF'
import sys, re

config_file = sys.argv[1]
trust_level = int(sys.argv[2])

try:
    with open(config_file) as f:
        lines = f.readlines()
except FileNotFoundError:
    sys.exit(0)

levels = {}
current_level = None

for line in lines:
    m = re.match(r'^\s{2}(L\d_\w+):\s*$', line)
    if m:
        current_level = m.group(1)
        levels[current_level] = {"trust_min": 0, "trust_max": 9999, "blocked_actions": [], "description": ""}
        continue

    if current_level is None:
        continue

    m = re.match(r'^\s+trust_min:\s*(\d+)', line)
    if m:
        levels[current_level]["trust_min"] = int(m.group(1))
        continue

    m = re.match(r'^\s+trust_max:\s*(\d+)', line)
    if m:
        levels[current_level]["trust_max"] = int(m.group(1))
        continue

    m = re.match(r'^\s+blocked_actions:\s*\[([^\]]*)\]', line)
    if m:
        raw = m.group(1).strip()
        if raw:
            levels[current_level]["blocked_actions"] = [x.strip() for x in raw.split(",")]
        continue

    m = re.match(r'^\s+description:\s*"([^"]*)"', line)
    if m:
        levels[current_level]["description"] = m.group(1)
        continue

for name, props in levels.items():
    if props["trust_min"] <= trust_level <= props["trust_max"]:
        print(f"description:{props['description']}")
        if props["blocked_actions"]:
            print(f"blocked:{', '.join(props['blocked_actions'])}")
        else:
            print("blocked:(yok)")
        break
PYEOF
)

  local desc blocked_list
  desc=$(echo "$blocked" | grep '^description:' | cut -d: -f2-)
  blocked_list=$(echo "$blocked" | grep '^blocked:' | cut -d: -f2-)

  [[ -n "$desc" ]] && echo -e "  Aciklama: $desc"
  [[ -n "$blocked_list" ]] && echo -e "  Engelli:  ${YELLOW}$blocked_list${NC}"
}

# -------------------------------------------------------------------
# stats komutu
# -------------------------------------------------------------------

cmd_stats() {
  ensure_db
  echo -e "${BLUE}=== Governance Istatistikleri ===${NC}"
  echo ""

  echo "--- Toplam Islem ---"
  sqlite3 "$AUDIT_DB" "SELECT COUNT(*) as toplam FROM audit_log;" 2>/dev/null || echo "0"

  echo ""
  echo "--- Son 24 Saat ---"
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT agent, COUNT(*) as islem, SUM(CASE WHEN result='DENY' THEN 1 ELSE 0 END) as deny_sayi, SUM(CASE WHEN result='WARN' THEN 1 ELSE 0 END) as warn_sayi FROM audit_log WHERE timestamp >= datetime('now', '-24 hours', 'localtime') GROUP BY agent ORDER BY islem DESC;" \
    2>/dev/null || echo "(veri yok)"

  echo ""
  echo "--- Rate Limitler (bu saat) ---"
  local current_hour
  current_hour=$(date '+%Y-%m-%d-%H')
  sqlite3 -header -column "$AUDIT_DB" \
    "SELECT agent, action_type, count FROM rate_counters WHERE hour='$current_hour' ORDER BY count DESC;" \
    2>/dev/null || echo "(veri yok)"

  echo ""
  echo "--- Trust Scores ---"
  cmd_trust

  echo ""
  echo "--- DB Boyutu ---"
  du -h "$AUDIT_DB" 2>/dev/null || echo "(db yok)"

  echo ""
  echo "--- Mod: $(get_mode) ---"
}

# -------------------------------------------------------------------
# Ana giris
# -------------------------------------------------------------------

usage() {
  cat <<EOF
governance.sh — Agent Governance Enforcement Engine

Kullanim:
  governance.sh check <agent> <action> [args]  — Policy evaluation
  governance.sh audit [agent] [--last N]        — Audit log goruntuleme
  governance.sh report [--weekly]               — Governance raporu
  governance.sh trust [agent] [+N|-N|=N]        — Trust score yonetimi
  governance.sh autonomy <agent>                — Autonomy level goruntuleme
  governance.sh stats                           — Rate limit durumlari

Ornekler:
  governance.sh check primary-agent exec "ls -la"
  governance.sh check social-agent exec "rm -rf /tmp"
  governance.sh audit --last 10
  governance.sh audit primary-agent --last 5
  governance.sh report --weekly
  governance.sh trust social-agent +50
  governance.sh autonomy primary-agent
  governance.sh stats

Policy: ~/.agent-evolution/config/governance.yaml
Audit DB: ~/.agent-evolution/governance/audit.db
EOF
}

main() {
  local cmd="${1:-}"
  shift 2>/dev/null || true

  case "$cmd" in
    check)     cmd_check "$@" ;;
    audit)     cmd_audit "$@" ;;
    report)    cmd_report "$@" ;;
    trust)     cmd_trust "$@" ;;
    autonomy)  cmd_autonomy "$@" ;;
    stats)     cmd_stats "$@" ;;
    -h|--help|help|"") usage ;;
    *)
      echo -e "${RED}Bilinmeyen komut: $cmd${NC}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
