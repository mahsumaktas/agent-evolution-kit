#!/bin/bash
# STANDBY: HTN hedef agaci yonetimi — manual kullanim. Gelecekte briefing entegrasyonu.
# goal-decompose.sh — HTN-style goal decomposition engine
# Usage: goal-decompose.sh <command> [args]
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
GOALS_DIR="$HOME/clawd/memory/goals"
GOALS_FILE="$GOALS_DIR/active-goals.json"
ARCHIVE_DIR="$GOALS_DIR/archive"
BRIEFINGS_DIR="$HOME/clawd/memory/briefings"

mkdir -p "$GOALS_DIR" "$ARCHIVE_DIR" "$BRIEFINGS_DIR"

# Initialize goals file if missing
if [[ ! -f "$GOALS_FILE" ]]; then
    cat > "$GOALS_FILE" <<'INIT'
{
  "goals": [],
  "metadata": {
    "created": "",
    "lastModified": ""
  }
}
INIT
    # Stamp creation time
    local_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 - "$GOALS_FILE" "$local_ts" <<'PYEOF'
import json, sys
f = sys.argv[1]
ts = sys.argv[2]
with open(f) as fh:
    d = json.load(fh)
d["metadata"]["created"] = ts
d["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PYEOF
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

stamp_modified() {
    python3 - "$GOALS_FILE" "$(now_ts)" <<'PYEOF'
import json, sys
f, ts = sys.argv[1], sys.argv[2]
with open(f) as fh:
    d = json.load(fh)
d["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
PYEOF
}

progress_bar() {
    local pct=$1 width=${2:-10}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    echo "$bar"
}

usage() {
    cat <<EOF
goal-decompose.sh — HTN-style goal decomposition engine

Komutlar:
  show                                     Hedef agacini goster
  add <title> [--deadline Q] [--parent id] Hedef ekle
  update <goal_id> --progress N            Ilerleme guncelle (0-100)
  assign <goal_id> --agent <name>          Agent ata
  weekly-report                            Haftalik rapor olustur
  suggest                                  Sonraki adim onerileri
  archive <goal_id>                        Tamamlanan hedefe arsivle
  priority [<goal_id> <P0-P4>]              Oncelik goster/ata

Ornekler:
  $0 add "Technical COO olmak" --deadline 2027-Q2
  $0 add "AI/ML bilgi derinlestir" --parent g1
  $0 update g1.1 --progress 40
  $0 assign g1.1 --agent scout+analyst
  $0 show
  $0 weekly-report
  $0 archive g1.3
  $0 priority
  $0 priority g1 P1
EOF
    exit 0
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_show() {
    python3 - "$GOALS_FILE" <<'PYEOF'
import json, sys

def progress_bar(pct, width=10):
    filled = int(pct * width / 100)
    return "█" * filled + "░" * (width - filled)

def format_task(t, prefix=""):
    metric = f" [{t.get('current',0)}/{t.get('target','?')}]" if 'target' in t else ""
    status = t.get("status", "active")
    icon = "●" if status == "active" else ("✓" if status == "done" else "○")
    return f"{prefix}{icon} {t['id']}: {t['title']}{metric}"

def show_goal(g, indent=0, is_last=False, parent_prefix=""):
    pct = g.get("progress", 0)
    bar = progress_bar(pct)
    deadline = f" (deadline: {g['deadline']})" if g.get("deadline") else ""
    owner = f" @{g['owner']}" if g.get("owner") else ""

    if indent == 0:
        prefix = ""
        line = f"{g['id']}: {g['title']} [{bar}] {pct}%{deadline}{owner}"
    else:
        connector = "└── " if is_last else "├── "
        line = f"{parent_prefix}{connector}{g['id']}: {g['title']} [{bar}] {pct}%{deadline}{owner}"

    print(line)

    children = g.get("subgoals", []) + g.get("tasks", [])
    for i, child in enumerate(children):
        child_is_last = (i == len(children) - 1)
        if indent == 0:
            new_prefix = ""
        else:
            new_prefix = parent_prefix + ("    " if is_last else "│   ")

        if "subgoals" in child or "tasks" in child or "progress" in child:
            show_goal(child, indent + 1, child_is_last, new_prefix if indent > 0 else "")
        else:
            connector = "└── " if child_is_last else "├── "
            child_prefix = new_prefix if indent > 0 else ""
            print(format_task(child, f"{child_prefix}{connector}"))

with open(sys.argv[1]) as f:
    data = json.load(f)

goals = data.get("goals", [])
if not goals:
    print("Aktif hedef yok. 'add' ile hedef ekleyin.")
    sys.exit(0)

for i, g in enumerate(goals):
    if i > 0:
        print()
    show_goal(g)
PYEOF
}

cmd_add() {
    local title=""
    local deadline=""
    local parent=""

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deadline) deadline="$2"; shift 2 ;;
            --parent)   parent="$2"; shift 2 ;;
            *)          title="$1"; shift ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "Hata: Baslik gerekli."
        echo "Kullanim: $0 add <title> [--deadline YYYY-QN] [--parent goal_id]"
        exit 1
    fi

    python3 - "$GOALS_FILE" "$title" "$deadline" "$parent" "$(now_ts)" <<'PYEOF'
import json, sys, re

f = sys.argv[1]
title = sys.argv[2]
deadline = sys.argv[3] if sys.argv[3] else None
parent_id = sys.argv[4] if sys.argv[4] else None
ts = sys.argv[5]

def detect_priority(text):
    """Match keywords from priority-rules.yaml logic"""
    text_lower = text.lower()
    p0_kws = ["security", "data-loss", "urgent-production", "critical", "emergency"]
    p1_kws = ["bug", "fix", "broken", "regression", "production-issue"]
    p3_kws = ["research", "improvement", "nice-to-have", "exploration"]
    p4_kws = ["cleanup", "optimization", "refactor", "archive", "housekeeping"]
    for kw in p0_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P0"
    for kw in p1_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P1"
    for kw in p3_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P3"
    for kw in p4_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P4"
    return "P2"

with open(f) as fh:
    data = json.load(fh)

def find_goal(goals, gid):
    """Recursively find a goal by id."""
    for g in goals:
        if g["id"] == gid:
            return g
        for sub in g.get("subgoals", []):
            found = find_goal([sub], gid)
            if found:
                return found
    return None

def next_id(goals, prefix="g"):
    """Generate next id at a given level."""
    max_n = 0
    for g in goals:
        parts = g["id"].split(".")
        try:
            n = int(parts[-1].replace("g", ""))
            if n > max_n:
                max_n = n
        except ValueError:
            pass
    return f"{prefix}{max_n + 1}" if "." in prefix else f"g{max_n + 1}"

if parent_id:
    parent = find_goal(data["goals"], parent_id)
    if not parent:
        print(f"Hata: '{parent_id}' bulunamadi.")
        sys.exit(1)
    if "subgoals" not in parent:
        parent["subgoals"] = []
    existing = parent.get("subgoals", [])
    new_id = f"{parent_id}.{len(existing) + 1}"
    priority = detect_priority(title)
    new_goal = {
        "id": new_id,
        "title": title,
        "priority": priority,
        "progress": 0,
        "status": "active",
        "created": ts
    }
    if deadline:
        new_goal["deadline"] = deadline
    parent["subgoals"].append(new_goal)
    print(f"Alt-hedef eklendi: {new_id} — {title} [{priority}]")
else:
    new_id = next_id(data["goals"])
    priority = detect_priority(title)
    new_goal = {
        "id": new_id,
        "title": title,
        "priority": priority,
        "progress": 0,
        "subgoals": [],
        "status": "active",
        "created": ts
    }
    if deadline:
        new_goal["deadline"] = deadline
    data["goals"].append(new_goal)
    print(f"Hedef eklendi: {new_id} — {title} [{priority}]")

data["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
PYEOF
}

cmd_update() {
    local goal_id=""
    local progress=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --progress) progress="$2"; shift 2 ;;
            *)          goal_id="$1"; shift ;;
        esac
    done

    if [[ -z "$goal_id" || -z "$progress" ]]; then
        echo "Hata: goal_id ve --progress gerekli."
        echo "Kullanim: $0 update <goal_id> --progress N"
        exit 1
    fi

    python3 - "$GOALS_FILE" "$goal_id" "$progress" "$(now_ts)" <<'PYEOF'
import json, sys

f = sys.argv[1]
gid = sys.argv[2]
progress = int(sys.argv[3])
ts = sys.argv[4]

if progress < 0 or progress > 100:
    print("Hata: Progress 0-100 araliginda olmali.")
    sys.exit(1)

with open(f) as fh:
    data = json.load(fh)

def find_and_update(goals, gid, progress):
    for g in goals:
        if g["id"] == gid:
            old = g.get("progress", 0)
            g["progress"] = progress
            if progress >= 100:
                g["status"] = "done"
            return old
        for sub in g.get("subgoals", []):
            result = find_and_update([sub], gid, progress)
            if result is not None:
                return result
        for t in g.get("tasks", []):
            if t["id"] == gid:
                old = t.get("current", 0)
                t["current"] = progress
                if "target" in t and progress >= t["target"]:
                    t["status"] = "done"
                return old
    return None

old = find_and_update(data["goals"], gid, progress)
if old is None:
    print(f"Hata: '{gid}' bulunamadi.")
    sys.exit(1)

data["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)

print(f"Guncellendi: {gid} — {old} -> {progress}")
PYEOF
}

cmd_assign() {
    local goal_id=""
    local agent=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent) agent="$2"; shift 2 ;;
            *)       goal_id="$1"; shift ;;
        esac
    done

    if [[ -z "$goal_id" || -z "$agent" ]]; then
        echo "Hata: goal_id ve --agent gerekli."
        echo "Kullanim: $0 assign <goal_id> --agent <name>"
        exit 1
    fi

    python3 - "$GOALS_FILE" "$goal_id" "$agent" "$(now_ts)" <<'PYEOF'
import json, sys

f = sys.argv[1]
gid = sys.argv[2]
agent = sys.argv[3]
ts = sys.argv[4]

with open(f) as fh:
    data = json.load(fh)

def find_and_assign(goals, gid, agent):
    for g in goals:
        if g["id"] == gid:
            g["owner"] = agent
            return True
        for sub in g.get("subgoals", []):
            if find_and_assign([sub], gid, agent):
                return True
    return False

if not find_and_assign(data["goals"], gid, agent):
    print(f"Hata: '{gid}' bulunamadi.")
    sys.exit(1)

data["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)

print(f"Atandi: {gid} -> @{agent}")
PYEOF
}

cmd_weekly_report() {
    local report_file="$BRIEFINGS_DIR/weekly-goals-$(date +%Y-%m-%d).md"

    python3 - "$GOALS_FILE" "$report_file" <<'PYEOF'
import json, sys
from datetime import datetime

goals_file = sys.argv[1]
report_file = sys.argv[2]

with open(goals_file) as f:
    data = json.load(f)

def bar(pct, width=10):
    filled = int(pct * width / 100)
    return "█" * filled + "░" * (width - filled)

lines = []
lines.append(f"# Haftalik Hedef Raporu — {datetime.now().strftime('%Y-%m-%d')}")
lines.append("")

goals = data.get("goals", [])
if not goals:
    lines.append("Aktif hedef yok.")
else:
    # Summary
    total = len(goals)
    avg_progress = sum(g.get("progress", 0) for g in goals) / total if total else 0
    lines.append(f"**Toplam hedef:** {total} | **Ortalama ilerleme:** {avg_progress:.0f}%")
    lines.append("")

    for g in goals:
        pct = g.get("progress", 0)
        deadline = g.get("deadline", "?")
        lines.append(f"## {g['id']}: {g['title']}")
        lines.append(f"Ilerleme: `[{bar(pct)}]` {pct}% | Deadline: {deadline}")
        lines.append("")

        for sub in g.get("subgoals", []):
            spct = sub.get("progress", 0)
            owner = f"@{sub['owner']}" if sub.get("owner") else ""
            lines.append(f"- **{sub['id']}:** {sub['title']} `[{bar(spct)}]` {spct}% {owner}")

            for t in sub.get("tasks", []):
                curr = t.get("current", 0)
                target = t.get("target", "?")
                status_icon = "done" if t.get("status") == "done" else "active"
                lines.append(f"  - {t['id']}: {t['title']} [{curr}/{target}] ({status_icon})")

        lines.append("")

    # Blockers / at-risk
    lines.append("## Dikkat Gerektiren")
    at_risk = []
    for g in goals:
        if g.get("deadline"):
            pct = g.get("progress", 0)
            # Simple heuristic: if progress < 25% and deadline within a year
            if pct < 25:
                at_risk.append(f"- {g['id']}: {g['title']} — {pct}% (deadline: {g['deadline']})")
        for sub in g.get("subgoals", []):
            if sub.get("progress", 0) < 10:
                at_risk.append(f"- {sub['id']}: {sub['title']} — {sub.get('progress',0)}%")
    if at_risk:
        lines.extend(at_risk)
    else:
        lines.append("- Risk altinda hedef yok.")

report = "\n".join(lines) + "\n"
with open(report_file, "w") as f:
    f.write(report)

print(report)
print(f"\nRapor kaydedildi: {report_file}")
PYEOF
}

cmd_suggest() {
    python3 - "$GOALS_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

print("Hedef Analizi — Oneriler")
print("=" * 40)

suggestions = []

def analyze(goals, depth=0):
    for g in goals:
        pct = g.get("progress", 0)
        gid = g["id"]
        title = g["title"]

        # No subgoals = needs decomposition
        subs = g.get("subgoals", [])
        tasks = g.get("tasks", [])
        if not subs and not tasks and depth == 0:
            suggestions.append(("decompose", gid, f"'{title}' alt-hedeflere bolunmeli"))

        # No owner
        if not g.get("owner") and depth > 0:
            suggestions.append(("assign", gid, f"'{title}' icin agent atanmali"))

        # Stalled (low progress, has children)
        if pct < 10 and (subs or tasks):
            child_progress = [s.get("progress", 0) for s in subs]
            if child_progress and max(child_progress) < 5:
                suggestions.append(("stalled", gid, f"'{title}' durmus gorunuyor — aksiyon gerekli"))

        # High progress — consider completing
        if pct >= 90 and pct < 100:
            suggestions.append(("complete", gid, f"'{title}' %{pct} — tamamlanmaya yakin"))

        # Tasks near target
        for t in tasks:
            if "target" in t:
                ratio = t.get("current", 0) / t["target"] if t["target"] > 0 else 0
                if ratio >= 0.9 and t.get("status") != "done":
                    suggestions.append(("task-done", t["id"], f"'{t['title']}' hedefe yakin — bitirebilir"))

        analyze(subs, depth + 1)

analyze(data.get("goals", []))

if not suggestions:
    print("Tum hedefler yolunda gorunuyor.")
else:
    priorities = {"stalled": 1, "decompose": 2, "assign": 3, "complete": 4, "task-done": 5}
    suggestions.sort(key=lambda x: priorities.get(x[0], 99))
    for stype, gid, msg in suggestions:
        tag = stype.upper()
        print(f"  [{tag}] {gid}: {msg}")

print()
PYEOF
}

cmd_archive() {
    local goal_id="${1:-}"

    if [[ -z "$goal_id" ]]; then
        echo "Hata: goal_id gerekli."
        echo "Kullanim: $0 archive <goal_id>"
        exit 1
    fi

    python3 - "$GOALS_FILE" "$ARCHIVE_DIR" "$goal_id" "$(now_ts)" <<'PYEOF'
import json, sys, os

goals_file = sys.argv[1]
archive_dir = sys.argv[2]
gid = sys.argv[3]
ts = sys.argv[4]

with open(goals_file) as f:
    data = json.load(f)

# Find and remove goal
removed = None

def remove_goal(goals, gid):
    for i, g in enumerate(goals):
        if g["id"] == gid:
            return goals.pop(i)
        subs = g.get("subgoals", [])
        for j, sub in enumerate(subs):
            if sub["id"] == gid:
                return subs.pop(j)
    return None

removed = remove_goal(data["goals"], gid)
if not removed:
    print(f"Hata: '{gid}' bulunamadi.")
    sys.exit(1)

# Save to archive
removed["archivedAt"] = ts
removed["status"] = "archived"

archive_file = os.path.join(archive_dir, f"{gid}-{ts[:10]}.json")
with open(archive_file, "w") as f:
    json.dump(removed, f, indent=2, ensure_ascii=False)

# Update goals file
data["metadata"]["lastModified"] = ts
with open(goals_file, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f"Arsivlendi: {gid} — {removed['title']}")
print(f"Arsiv dosyasi: {archive_file}")
PYEOF
}

# ─── Priority management ──────────────────────────────────────────────────────
cmd_priority() {
    local goal_id="${1:-}"
    local new_priority="${2:-}"

    if [[ -n "$goal_id" && -n "$new_priority" ]]; then
        # Set priority on a specific goal
        if [[ ! "$new_priority" =~ ^P[0-4]$ ]]; then
            echo "Hata: Gecersiz oncelik '$new_priority'. P0-P4 araliginda olmali."
            exit 1
        fi
        python3 - "$GOALS_FILE" "$goal_id" "$new_priority" "$(now_ts)" <<'PYEOF'
import json, sys

f = sys.argv[1]
gid = sys.argv[2]
priority = sys.argv[3]
ts = sys.argv[4]

with open(f) as fh:
    data = json.load(fh)

def find_and_set_priority(goals, gid, priority):
    for g in goals:
        if g["id"] == gid:
            old = g.get("priority", "N/A")
            g["priority"] = priority
            return old
        for sub in g.get("subgoals", []):
            result = find_and_set_priority([sub], gid, priority)
            if result is not None:
                return result
    return None

old = find_and_set_priority(data["goals"], gid, priority)
if old is None:
    print(f"Hata: '{gid}' bulunamadi.")
    sys.exit(1)

data["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)

print(f"Oncelik guncellendi: {gid} — {old} -> {priority}")
PYEOF
    else
        # List all goals with their priorities (+ auto-suggest for missing)
        python3 - "$GOALS_FILE" <<'PYEOF'
import json, sys, re

def detect_priority(text):
    """Match keywords from priority-rules.yaml logic"""
    text_lower = text.lower()
    p0_kws = ["security", "data-loss", "urgent-production", "critical", "emergency"]
    p1_kws = ["bug", "fix", "broken", "regression", "production-issue"]
    p3_kws = ["research", "improvement", "nice-to-have", "exploration"]
    p4_kws = ["cleanup", "optimization", "refactor", "archive", "housekeeping"]
    for kw in p0_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P0"
    for kw in p1_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P1"
    for kw in p3_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P3"
    for kw in p4_kws:
        if re.search(r'\b' + re.escape(kw) + r'\b', text_lower):
            return "P4"
    return "P2"

with open(sys.argv[1]) as f:
    data = json.load(f)

print("Hedef Oncelikleri")
print("=" * 50)

def list_priorities(goals, indent=0):
    for g in goals:
        prefix = "  " * indent
        current = g.get("priority", None)
        suggested = detect_priority(g["title"])
        if current:
            marker = f"[{current}]"
            if current != suggested:
                marker += f" (onerilen: {suggested})"
        else:
            marker = f"[--] (onerilen: {suggested})"
        print(f"{prefix}{g['id']}: {g['title']} {marker}")
        list_priorities(g.get("subgoals", []), indent + 1)

goals = data.get("goals", [])
if not goals:
    print("Aktif hedef yok.")
else:
    list_priorities(goals)

print()
PYEOF
    fi
}

# ─── Recalculate parent progress from children ───────────────────────────────
cmd_recalc() {
    python3 - "$GOALS_FILE" "$(now_ts)" <<'PYEOF'
import json, sys

f = sys.argv[1]
ts = sys.argv[2]

with open(f) as fh:
    data = json.load(fh)

def recalc(g):
    subs = g.get("subgoals", [])
    tasks = g.get("tasks", [])
    children = subs + tasks
    if not children:
        return g.get("progress", 0)

    for s in subs:
        recalc(s)

    total = 0
    count = 0
    for s in subs:
        total += s.get("progress", 0)
        count += 1
    for t in tasks:
        if "target" in t and t["target"] > 0:
            total += min(100, int(t.get("current", 0) / t["target"] * 100))
        else:
            total += 100 if t.get("status") == "done" else 0
        count += 1

    if count > 0:
        new_pct = int(total / count)
        old_pct = g.get("progress", 0)
        if new_pct != old_pct:
            print(f"  {g['id']}: {old_pct}% -> {new_pct}%")
        g["progress"] = new_pct
    return g.get("progress", 0)

print("Progress yeniden hesaplaniyor...")
changed = False
for g in data.get("goals", []):
    recalc(g)

data["metadata"]["lastModified"] = ts
with open(f, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)

print("Tamamlandi.")
PYEOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────
cmd="${1:-}"
shift || true

case "$cmd" in
    show)           cmd_show ;;
    add)            cmd_add "$@" ;;
    update)         cmd_update "$@" ;;
    assign)         cmd_assign "$@" ;;
    weekly-report)  cmd_weekly_report ;;
    suggest)        cmd_suggest ;;
    archive)        cmd_archive "$@" ;;
    priority)       cmd_priority "$@" ;;
    recalc)         cmd_recalc ;;
    -h|--help|"")   usage ;;
    *)
        echo "Bilinmeyen komut: $cmd"
        usage
        ;;
esac
