#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# skill-discovery.sh — Capability gap detection, skill tracking, and composition
#
# Tracks which skills are used, their success rates, identifies gaps from
# failed trajectories, and suggests new skill combinations.
#
# Usage:
#   skill-discovery.sh gap-log <description>                  Log a capability gap
#   skill-discovery.sh gaps                                   List gaps by frequency
#   skill-discovery.sh track <skill> <success|failure> [ms]   Track skill usage
#   skill-discovery.sh performance                            Performance report
#   skill-discovery.sh compose <name> <skill1> <skill2> ...   Create composite skill
#   skill-discovery.sh compositions                           List composites
#   skill-discovery.sh suggest                                Suggest new skills
#   skill-discovery.sh report                                 Overall coverage report

set -euo pipefail

# === Configuration ===
AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"
MEMORY_DIR="$AEK_HOME/memory"
SKILLS_DIR="$AEK_HOME/skills"
GAP_LOG="$MEMORY_DIR/skill-gaps.jsonl"
METRICS_LOG="$MEMORY_DIR/skill-metrics.jsonl"
COMPOSITIONS_FILE="$SKILLS_DIR/compositions.json"

mkdir -p "$MEMORY_DIR" "$SKILLS_DIR"

# Initialize files if missing
[[ -f "$GAP_LOG" ]] || touch "$GAP_LOG"
[[ -f "$METRICS_LOG" ]] || touch "$METRICS_LOG"
if [[ ! -f "$COMPOSITIONS_FILE" ]]; then
    cat > "$COMPOSITIONS_FILE" <<'INIT'
{
  "compositions": [],
  "metadata": {
    "created": "",
    "lastModified": ""
  }
}
INIT
    local_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 - "$COMPOSITIONS_FILE" "$local_ts" <<'PYEOF'
import json, sys
f, ts = sys.argv[1], sys.argv[2]
with open(f) as fh:
    d = json.load(fh)
d["metadata"]["created"] = ts
d["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PYEOF
fi

# === Helpers ===
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
    cat <<EOF
skill-discovery.sh — Capability Gap Detection & Skill Composition

Commands:
  gap-log <description>                       Log a capability gap
  gaps                                        List gaps sorted by frequency
  track <skill> <success|failure> [dur_ms]    Track skill execution
  performance                                 Performance report (last 30 days)
  compose <name> <skill1> <skill2> [...]      Create composite skill
  compositions                                List composite skills
  suggest                                     Suggest new skills based on gaps
  report                                      Overall skill coverage report

Examples:
  $0 gap-log "Cannot automatically check competitor prices"
  $0 track nightly-scan success 45200
  $0 compose price-monitor competitor-scan price-compare notify
  $0 performance
  $0 suggest
EOF
    exit 0
}

# === Commands ===

cmd_gap_log() {
    local desc="${1:-}"

    if [[ -z "$desc" ]]; then
        echo "Error: Description is required."
        echo "Usage: $0 gap-log <description>"
        exit 1
    fi

    python3 - "$GAP_LOG" "$desc" "$(now_ts)" <<'PYEOF'
import json, sys

gap_file = sys.argv[1]
desc = sys.argv[2]
ts = sys.argv[3]

lines = []
found = False
with open(gap_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if entry["description"].lower() == desc.lower():
            entry["frequency"] = entry.get("frequency", 1) + 1
            entry["lastSeen"] = ts
            found = True
        lines.append(json.dumps(entry, ensure_ascii=False))

if not found:
    new_entry = {
        "ts": ts,
        "description": desc,
        "context": "",
        "frequency": 1
    }
    lines.append(json.dumps(new_entry, ensure_ascii=False))

with open(gap_file, "w") as f:
    f.write("\n".join(lines) + "\n")

if found:
    print(f"Gap updated (frequency incremented): {desc}")
else:
    print(f"Gap logged: {desc}")
PYEOF
}

cmd_gaps() {
    python3 - "$GAP_LOG" <<'PYEOF'
import json, sys

gap_file = sys.argv[1]

entries = []
with open(gap_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entries.append(json.loads(line))

if not entries:
    print("No gaps recorded.")
    sys.exit(0)

entries.sort(key=lambda x: x.get("frequency", 1), reverse=True)

print("Capability Gaps (by frequency)")
print("=" * 50)
for e in entries:
    freq = e.get("frequency", 1)
    bar = "#" * min(freq, 20)
    ctx = f" [{e['context']}]" if e.get("context") else ""
    date = e.get("lastSeen", e.get("ts", "?"))[:10]
    print(f"  {freq:>3}x {bar:<20} {e['description']}{ctx} ({date})")

print(f"\nTotal: {len(entries)} gaps")
PYEOF
}

cmd_track() {
    local skill="${1:-}"
    local status="${2:-}"
    local duration="${3:-0}"
    local agent="${4:-}"

    if [[ -z "$skill" || -z "$status" ]]; then
        echo "Error: skill and status are required."
        echo "Usage: $0 track <skill> <success|failure> [duration_ms] [agent]"
        exit 1
    fi

    if [[ "$status" != "success" && "$status" != "failure" ]]; then
        echo "Error: status must be 'success' or 'failure'."
        exit 1
    fi

    python3 - "$METRICS_LOG" "$skill" "$status" "$duration" "$agent" "$(now_ts)" <<'PYEOF'
import json, sys

metrics_file = sys.argv[1]
skill = sys.argv[2]
status = sys.argv[3]
duration = int(sys.argv[4]) if sys.argv[4] else 0
agent = sys.argv[5] if sys.argv[5] else None
ts = sys.argv[6]

entry = {
    "ts": ts,
    "skill": skill,
    "status": status,
    "duration_ms": duration
}
if agent:
    entry["agent"] = agent

with open(metrics_file, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

dur_str = f" ({duration}ms)" if duration > 0 else ""
print(f"Recorded: {skill} -- {status}{dur_str}")
PYEOF
}

cmd_performance() {
    python3 - "$METRICS_LOG" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone

metrics_file = sys.argv[1]

entries = []
cutoff = datetime.now(timezone.utc) - timedelta(days=30)

with open(metrics_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        ts_str = entry.get("ts", "")
        try:
            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            if ts >= cutoff:
                entries.append(entry)
        except (ValueError, TypeError):
            entries.append(entry)

if not entries:
    print("No metrics in the last 30 days.")
    sys.exit(0)

skills = {}
for e in entries:
    name = e["skill"]
    if name not in skills:
        skills[name] = {"success": 0, "failure": 0, "durations": []}
    if e["status"] == "success":
        skills[name]["success"] += 1
    else:
        skills[name]["failure"] += 1
    dur = e.get("duration_ms", 0)
    if dur > 0:
        skills[name]["durations"].append(dur)

print("Skill Performance Report (last 30 days)")
print("-" * 50)

sorted_skills = sorted(skills.items(), key=lambda x: x[1]["success"] + x[1]["failure"], reverse=True)
max_name_len = max(len(name) for name, _ in sorted_skills) if sorted_skills else 15

for name, data in sorted_skills:
    total = data["success"] + data["failure"]
    rate = data["success"] / total * 100 if total > 0 else 0
    bar_width = 10
    filled = int(rate * bar_width / 100)
    bar = "#" * filled + "." * (bar_width - filled)

    avg_dur = ""
    if data["durations"]:
        avg_ms = sum(data["durations"]) / len(data["durations"])
        if avg_ms >= 60000:
            avg_dur = f"  avg: {avg_ms/60000:.1f}m"
        elif avg_ms >= 1000:
            avg_dur = f"  avg: {avg_ms/1000:.1f}s"
        else:
            avg_dur = f"  avg: {avg_ms:.0f}ms"

    print(f"  {name:<{max_name_len}} {bar} {rate:>4.0f}% ({data['success']}/{total}){avg_dur}")

print(f"\nTotal: {len(sorted_skills)} skills, {sum(s['success']+s['failure'] for _,s in sorted_skills)} executions")
PYEOF
}

cmd_compose() {
    local name="${1:-}"
    shift || true
    local components=("$@")

    if [[ -z "$name" || ${#components[@]} -lt 2 ]]; then
        echo "Error: Name and at least 2 skills are required."
        echo "Usage: $0 compose <name> <skill1> <skill2> [skill3...]"
        exit 1
    fi

    local components_json
    components_json=$(printf '%s\n' "${components[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))")

    python3 - "$COMPOSITIONS_FILE" "$name" "$components_json" "$(now_ts)" <<'PYEOF'
import json, sys

comp_file = sys.argv[1]
name = sys.argv[2]
components = json.loads(sys.argv[3])
ts = sys.argv[4]

with open(comp_file) as f:
    data = json.load(f)

for c in data.get("compositions", []):
    if c["name"] == name:
        print(f"Error: '{name}' already exists.")
        sys.exit(1)

new_comp = {
    "name": name,
    "components": components,
    "created": ts,
    "executionCount": 0,
    "lastUsed": None
}

data["compositions"].append(new_comp)
data["metadata"]["lastModified"] = ts

with open(comp_file, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f"Composite skill created: {name}")
print(f"  Components: {' + '.join(components)}")
PYEOF
}

cmd_compositions() {
    python3 - "$COMPOSITIONS_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

compositions = data.get("compositions", [])
if not compositions:
    print("No composite skills registered.")
    sys.exit(0)

print("Composite Skill Registry")
print("=" * 50)
for c in compositions:
    components = " + ".join(c["components"])
    count = c.get("executionCount", 0)
    last = c.get("lastUsed", "-")
    if last and last != "null":
        last = last[:10]
    else:
        last = "-"
    print(f"  {c['name']}")
    print(f"    Components: {components}")
    print(f"    Executions: {count}x | Last used: {last}")
    print()

print(f"Total: {len(compositions)} composite skills")
PYEOF
}

cmd_suggest() {
    python3 - "$GAP_LOG" "$METRICS_LOG" "$COMPOSITIONS_FILE" "$SKILLS_DIR" <<'PYEOF'
import json, sys, os, glob

gap_file = sys.argv[1]
metrics_file = sys.argv[2]
comp_file = sys.argv[3]
skills_dir = sys.argv[4]

# Load gaps
gaps = []
if os.path.getsize(gap_file) > 0:
    with open(gap_file, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            gaps.append(json.loads(line))

# Load existing skill names
existing_skills = set()
for p in glob.glob(os.path.join(skills_dir, "*")):
    name = os.path.basename(p)
    if name != "compositions.json":
        existing_skills.add(name.replace(".sh", "").replace(".py", ""))

# Load compositions
with open(comp_file) as f:
    comp_data = json.load(f)
comp_names = {c["name"] for c in comp_data.get("compositions", [])}

# Load metrics for context
skill_stats = {}
if os.path.getsize(metrics_file) > 0:
    with open(metrics_file, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            name = e["skill"]
            if name not in skill_stats:
                skill_stats[name] = {"success": 0, "failure": 0}
            skill_stats[name][e["status"]] = skill_stats[name].get(e["status"], 0) + 1

print("Skill Suggestions")
print("=" * 50)

if not gaps:
    print("No gaps recorded -- use gap-log command to record capability gaps.")
    sys.exit(0)

gaps.sort(key=lambda x: x.get("frequency", 1), reverse=True)

print()
print("1. Priority Gaps (by frequency):")
print("-" * 40)
for g in gaps[:10]:
    freq = g.get("frequency", 1)
    desc = g["description"]
    priority = "HIGH" if freq >= 5 else ("MEDIUM" if freq >= 2 else "LOW")
    print(f"  [{priority}] {desc} ({freq}x)")

# Suggest combinations
print()
print("2. Possible Skill Combinations:")
print("-" * 40)
skill_list = sorted(existing_skills)
suggested_any = False

for g in gaps[:5]:
    desc_lower = g["description"].lower()
    matching_skills = []
    for s in skill_list:
        s_words = s.replace("-", " ").replace("_", " ").split()
        for w in s_words:
            if len(w) > 3 and w.lower() in desc_lower:
                matching_skills.append(s)
                break

    if len(matching_skills) >= 2:
        suggested_any = True
        combo = " + ".join(matching_skills[:3])
        print(f"  Gap: \"{g['description']}\"")
        print(f"  Suggestion: [{combo}] could address this")
        print()

if not suggested_any:
    print("  No automatic combinations found from existing skills.")
    print("  Use 'compose' command to create combinations manually.")

# Suggest new standalone skills
print()
print("3. New Skill Suggestions:")
print("-" * 40)
for g in gaps[:5]:
    desc = g["description"]
    freq = g.get("frequency", 1)
    words = desc.lower().replace(",", "").replace(".", "").split()
    stop_words = {"the", "a", "an", "is", "are", "to", "of", "in", "for", "not",
                  "can", "cannot", "can't", "automatically", "be", "this", "that",
                  "with", "from", "and", "or", "but", "no", "has", "have", "does"}
    key_words = [w for w in words if w not in stop_words and len(w) > 2][:3]
    slug = "-".join(key_words) if key_words else "new-skill"

    if slug not in existing_skills and slug not in comp_names:
        print(f"  Suggestion: create '{slug}' skill")
        print(f"    Source: \"{desc}\" ({freq}x)")
        print()

# Failing skills
failing = []
for name, stats in skill_stats.items():
    total = stats["success"] + stats["failure"]
    if total >= 3 and stats["failure"] / total > 0.3:
        rate = stats["failure"] / total * 100
        failing.append((name, rate, total))

if failing:
    print()
    print("4. Underperforming Skills (>30% failure rate):")
    print("-" * 40)
    failing.sort(key=lambda x: x[1], reverse=True)
    for name, rate, total in failing:
        print(f"  {name}: {rate:.0f}% failure ({total} executions) -- consider rewriting")

print()
PYEOF
}

cmd_report() {
    echo "## Skill Coverage Report"
    echo "### $(date '+%Y-%m-%d %H:%M')"
    echo ""

    # Skill count
    local skill_count
    skill_count=$(find "$SKILLS_DIR" -maxdepth 1 -not -name "compositions.json" -not -name "." 2>/dev/null | wc -l | tr -d ' ')
    echo "  Registered skills: $skill_count"

    # Gap count
    local gap_count=0
    if [[ -s "$GAP_LOG" ]]; then
        gap_count=$(wc -l < "$GAP_LOG" | tr -d ' ')
    fi
    echo "  Open gaps: $gap_count"

    # Composition count
    local comp_count
    comp_count=$(python3 - "$COMPOSITIONS_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(len(json.load(f).get('compositions', [])))
except:
    print(0)
PYEOF
)
    echo "  Composite skills: $comp_count"

    echo ""
    echo "### Performance Summary"
    cmd_performance 2>/dev/null || echo "  No performance data available."

    echo ""
    echo "### Top Gaps"
    cmd_gaps 2>/dev/null || echo "  No gaps recorded."
}

# === Main ===
cmd="${1:-}"
shift || true

case "$cmd" in
    gap-log)        cmd_gap_log "$@" ;;
    gaps)           cmd_gaps ;;
    track)          cmd_track "$@" ;;
    performance)    cmd_performance ;;
    compose)        cmd_compose "$@" ;;
    compositions)   cmd_compositions ;;
    suggest)        cmd_suggest ;;
    report)         cmd_report ;;
    -h|--help|"")   usage ;;
    *)
        echo "Unknown command: $cmd"
        usage
        ;;
esac
