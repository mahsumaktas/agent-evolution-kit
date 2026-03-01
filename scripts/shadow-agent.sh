#!/usr/bin/env bash
# shadow-agent.sh — Shadow agent observer system
# Reads config/shadow-agents.yaml, runs observer reviews on trigger conditions.
#
# Usage:
#   shadow-agent.sh review --target <agent> --trigger <trigger>
#   shadow-agent.sh status
#   shadow-agent.sh batch
set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
CONFIG="$AEK_HOME/config/shadow-agents.yaml"
BRIDGE="$AEK_HOME/scripts/bridge.sh"
SHADOW_DIR="$AEK_HOME/memory/shadow-reviews"
TRAJECTORY="$AEK_HOME/memory/trajectory-pool.json"
TODAY=$(date +%Y-%m-%d)
COOLDOWN_HOURS=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[shadow]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[shadow]${NC} $1" >&2; }
err() { echo -e "${RED}[shadow]${NC} $1" >&2; }

mkdir -p "$SHADOW_DIR"

# --- YAML parser (no PyYAML dependency) ---
# Returns JSON array of shadow configs from the YAML file.
parse_config() {
    python3 - "$CONFIG" <<'PYEOF'
import sys, re, json

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

shadows = []
defaults = {}
current = None
section = None

for line in lines:
    stripped = line.rstrip()
    # Skip comments and blank lines
    if not stripped or stripped.lstrip().startswith('#'):
        continue

    indent = len(line) - len(line.lstrip())

    if stripped.startswith('shadows:'):
        section = 'shadows'
        continue
    elif stripped.startswith('defaults:'):
        section = 'defaults'
        continue

    if section == 'shadows':
        if stripped.lstrip().startswith('- observer:'):
            current = {}
            shadows.append(current)
            val = stripped.split(':', 1)[1].strip()
            current['observer'] = val
        elif current is not None and ':' in stripped:
            key, val = stripped.strip().lstrip('- ').split(':', 1)
            key = key.strip()
            val = val.strip()
            # Parse array syntax [a, b, c]
            if val.startswith('[') and val.endswith(']'):
                val = [x.strip().strip('"').strip("'") for x in val[1:-1].split(',')]
            elif val.isdigit():
                val = int(val)
            current[key] = val

    elif section == 'defaults':
        if ':' in stripped:
            key, val = stripped.strip().split(':', 1)
            key = key.strip()
            val = val.strip()
            if val.isdigit():
                val = int(val)
            defaults[key] = val

print(json.dumps({"shadows": shadows, "defaults": defaults}))
PYEOF
}

# --- Count today's reviews for an observer-target pair ---
count_today_reviews() {
    local target="$1" observer="$2"
    local count=0
    for f in "$SHADOW_DIR"/"$TODAY"-"$target"-*.md; do
        [[ -f "$f" ]] || continue
        # Check if observer matches (first line has observer info)
        if head -1 "$f" 2>/dev/null | grep -q "Observer: $observer" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# --- Check cooldown: was this target+trigger reviewed in last N hours? ---
check_cooldown() {
    local target="$1" trigger="$2"
    local cutoff
    cutoff=$(date -v-"${COOLDOWN_HOURS}"H +%s 2>/dev/null || date -d "-${COOLDOWN_HOURS} hours" +%s 2>/dev/null)
    for f in "$SHADOW_DIR"/"$TODAY"-"$target"-"$trigger"*.md; do
        [[ -f "$f" ]] || continue
        local fmod
        fmod=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
        if [[ "$fmod" -ge "$cutoff" ]]; then
            return 0  # In cooldown
        fi
    done
    return 1  # Not in cooldown
}

# --- Find matching observer for a target+trigger ---
find_observer() {
    local target="$1" trigger="$2"
    local config_json
    config_json=$(parse_config)

    python3 - "$config_json" "$target" "$trigger" <<'PYEOF'
import sys, json

config = json.loads(sys.argv[1])
target = sys.argv[2]
trigger = sys.argv[3]
defaults = config.get("defaults", {})

for s in config["shadows"]:
    if s.get("target") == target:
        triggers = s.get("speak_on", [])
        if trigger in triggers or "all" in triggers:
            limit = s.get("max_reviews_per_day", defaults.get("max_reviews_per_day", 5))
            model = s.get("model", defaults.get("model", "haiku"))
            print(json.dumps({
                "observer": s["observer"],
                "target": s["target"],
                "mode": s.get("mode", "passive"),
                "model": model,
                "max_reviews_per_day": limit
            }))
            sys.exit(0)

sys.exit(1)
PYEOF
}

# --- Run a single review ---
run_review() {
    local target="$1" trigger="$2" context="${3:-}"
    local match

    # Find matching observer
    match=$(find_observer "$target" "$trigger") || {
        warn "Eslesen observer bulunamadi: target=$target trigger=$trigger"
        return 1
    }

    local observer model max_limit mode
    IFS=$'\t' read -r observer model max_limit mode < <(
        echo "$match" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['observer'], d['model'], d['max_reviews_per_day'], d['mode'], sep='\t')
")

    # Daily limit check
    local today_count
    today_count=$(count_today_reviews "$target" "$observer")
    if [[ "$today_count" -ge "$max_limit" ]]; then
        warn "Gunluk limit asildi: $observer -> $target ($today_count/$max_limit)"
        return 2
    fi

    # Cooldown check
    if check_cooldown "$target" "$trigger"; then
        warn "Cooldown aktif: $target+$trigger (son ${COOLDOWN_HOURS}s icinde review yapilmis)"
        return 3
    fi

    # Build context from stdin if not provided
    if [[ -z "$context" && ! -t 0 ]]; then
        context=$(cat)
    fi
    if [[ -z "$context" ]]; then
        context="No additional context provided."
    fi

    local prompt
    prompt="You are a ${observer} agent reviewing ${target}'s work.
Trigger: ${trigger}
Mode: ${mode}
Task context: ${context}

Review concisely (max 100 words):
1. Quality assessment (APPROVE / SUGGEST / FLAG)
2. Specific observations (1-3 bullet points)
3. One actionable recommendation (if any)"

    log "Review baslatiliyor: $observer -> $target (trigger: $trigger, model: $model)"

    local outfile="$SHADOW_DIR/${TODAY}-${target}-${trigger}-$(date +%H%M%S).md"
    local result

    if [[ -x "$BRIDGE" ]]; then
        result=$("$BRIDGE" --quick --text --silent "$prompt" 2>/dev/null) || {
            err "Bridge cagrisi basarisiz"
            return 4
        }
    else
        err "Bridge bulunamadi: $BRIDGE"
        return 127
    fi

    # Save review
    {
        echo "<!-- Observer: $observer | Target: $target | Trigger: $trigger | Mode: $mode -->"
        echo "# Shadow Review: $observer -> $target"
        echo "**Date:** $TODAY $(date +%H:%M:%S)"
        echo "**Trigger:** $trigger"
        echo "**Mode:** $mode"
        echo ""
        echo "## Review"
        echo "$result"
    } > "$outfile"

    log "Review kaydedildi: $outfile"
    echo "$outfile"
}

# --- STATUS command ---
cmd_status() {
    local config_json
    config_json=$(parse_config)

    echo -e "${BOLD}Shadow Agent Configurations${NC}"
    echo "========================================="

    python3 - "$config_json" "$SHADOW_DIR" "$TODAY" <<'PYEOF'
import sys, json, os, glob

config = json.loads(sys.argv[1])
shadow_dir = sys.argv[2]
today = sys.argv[3]
defaults = config.get("defaults", {})

for s in config["shadows"]:
    obs = s["observer"]
    tgt = s["target"]
    mode = s.get("mode", "passive")
    triggers = s.get("speak_on", [])
    if isinstance(triggers, str):
        triggers = [triggers]
    limit = s.get("max_reviews_per_day", defaults.get("max_reviews_per_day", 5))
    model = s.get("model", defaults.get("model", "haiku"))

    # Count today's reviews
    pattern = os.path.join(shadow_dir, f"{today}-{tgt}-*.md")
    today_files = []
    for tf in glob.glob(pattern):
        with open(tf) as fh:
            if fh.readline().find(f"Observer: {obs}") >= 0:
                today_files.append(tf)
    count = len(today_files)

    status_icon = "OK" if count < limit else "LIMIT"
    print(f"\n  {obs} -> {tgt}")
    print(f"    Mode: {mode} | Model: {model}")
    print(f"    Triggers: {', '.join(triggers)}")
    print(f"    Today: {count}/{limit} [{status_icon}]")

# Defaults
print(f"\nDefaults:")
for k, v in defaults.items():
    print(f"  {k}: {v}")
PYEOF

    echo ""
    echo -e "${BOLD}Recent Reviews (last 5):${NC}"
    local found_reviews=false
    for f in $(ls -t "$SHADOW_DIR"/*.md 2>/dev/null | head -5); do
        found_reviews=true
        echo "  $(basename "$f")"
    done
    if [[ "$found_reviews" == "false" ]]; then
        echo "  (henuz review yok)"
    fi
}

# --- BATCH command ---
cmd_batch() {
    if [[ ! -f "$TRAJECTORY" ]]; then
        warn "Trajectory pool bulunamadi: $TRAJECTORY"
        return 1
    fi

    log "Batch review baslatiliyor (son 24 saat, max 5 entry)..."

    local entries
    entries=$(python3 - "$TRAJECTORY" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

entries = data.get("entries", []) if isinstance(data, dict) else data
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
recent = []

for e in reversed(entries):
    ts = e.get("timestamp", "")
    try:
        # Handle both Z suffix and +00:00
        ts_clean = ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts_clean)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        if dt >= cutoff:
            recent.append(e)
    except (ValueError, TypeError):
        continue
    if len(recent) >= 5:
        break

print(json.dumps(recent))
PYEOF
    )

    local count
    count=$(echo "$entries" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    if [[ "$count" -eq 0 ]]; then
        log "Son 24 saatte trajectory entry bulunamadi."
        return 0
    fi

    log "$count entry bulundu, review ediliyor..."

    local reviewed=0
    # Use NUL-delimited output to handle multiline task fields safely
    # Process substitution avoids subshell scope issue with reviewed counter
    while IFS=$'\t' read -r -d '' caller task result; do
        log "Batch review: caller=$caller result=$result"
        run_review "$caller" "task_complete" "Task: $task | Result: $result" 2>/dev/null && {
            reviewed=$((reviewed + 1))
        } || true
    done < <(echo "$entries" | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    caller = e.get('caller', e.get('agent', 'unknown'))
    task = e.get('task', 'no description').replace('\n', ' ').replace('\t', ' ')[:200]
    result = e.get('result', 'unknown')
    sys.stdout.write(f'{caller}\t{task}\t{result}\0')
")

    log "Batch tamamlandi: $reviewed review yapildi."
}

# --- USAGE ---
usage() {
    cat >&2 << 'EOF'
shadow-agent.sh — Shadow agent observer system

Kullanim:
  shadow-agent.sh review --target <agent> --trigger <trigger>
  shadow-agent.sh status
  shadow-agent.sh batch

Komutlar:
  review    Observer review calistir (matching config'e gore)
  status    Tum shadow konfigurasyonlarini ve bugunun review sayilarini goster
  batch     Son 24 saatteki trajectory entry'lerini toplu review et

Review Secenekleri:
  --target <agent>     Hedef agent adi (orn: writer, scout, finance-agent)
  --trigger <trigger>  Tetikleyici (orn: code_written, security_risk, task_complete)

Context stdin uzerinden de verilebilir:
  echo "task output" | shadow-agent.sh review --target writer --trigger code_written
EOF
    exit 1
}

# --- MAIN ---
if [[ $# -eq 0 ]]; then
    usage
fi

# Pre-flight checks
if [[ ! -f "$CONFIG" ]]; then
    err "Config bulunamadi: $CONFIG"
    exit 1
fi

COMMAND="$1"; shift

case "$COMMAND" in
    review)
        TARGET=""
        TRIGGER=""
        while [[ $# -gt 0 ]]; do
            case $1 in
                --target)  TARGET="$2"; shift 2;;
                --trigger) TRIGGER="$2"; shift 2;;
                --help|-h) usage;;
                *)         err "Bilinmeyen secenek: $1"; usage;;
            esac
        done
        if [[ -z "$TARGET" || -z "$TRIGGER" ]]; then
            err "--target ve --trigger zorunlu"
            usage
        fi
        run_review "$TARGET" "$TRIGGER"
        ;;
    status)
        cmd_status
        ;;
    batch)
        cmd_batch
        ;;
    --help|-h)
        usage
        ;;
    *)
        err "Bilinmeyen komut: $COMMAND"
        usage
        ;;
esac
