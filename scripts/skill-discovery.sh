#!/bin/bash
# STANDBY: Yetenek kesfi ve gap analizi — manual kullanim. Gelecekte weekly-cycle entegrasyonu.
# skill-discovery.sh — Capability gap detection and skill composition
# Usage: skill-discovery.sh <command> [args]
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
MEMORY_DIR="$HOME/clawd/memory"
SKILLS_DIR="$HOME/clawd/skills"
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

# ─── Helpers ──────────────────────────────────────────────────────────────────
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
    cat <<EOF
skill-discovery.sh — Capability gap detection & skill composition

Komutlar:
  gap-log <description>                       Eksik yetenek kaydet
  gaps                                        Eksiklikleri sirayla goster
  track <skill> <success|failure> [dur_ms]    Skill calismasini kaydet
  performance                                 Performans raporu
  compose <name> <skill1> <skill2> [...]      Bilesik skill olustur
  compositions                                Bilesik skill listesi
  suggest                                     Yeni skill onerileri

Ornekler:
  $0 gap-log "Rakip fiyat otomatik kontrol edilemiyor"
  $0 track nightly-scan success 45200
  $0 compose price-monitor competitor-scan price-compare notify
  $0 performance
  $0 suggest
EOF
    exit 0
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_gap_log() {
    local desc="${1:-}"

    if [[ -z "$desc" ]]; then
        echo "Hata: Aciklama gerekli."
        echo "Kullanim: $0 gap-log <description>"
        exit 1
    fi

    python3 - "$GAP_LOG" "$desc" "$(now_ts)" <<'PYEOF'
import json, sys

gap_file = sys.argv[1]
desc = sys.argv[2]
ts = sys.argv[3]

# Check if similar gap exists (increment frequency)
lines = []
found = False
with open(gap_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        # Simple similarity: exact description match
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
    print(f"Gap guncellendi (frekans artti): {desc}")
else:
    print(f"Gap kaydedildi: {desc}")
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
    print("Kayitli gap yok.")
    sys.exit(0)

# Sort by frequency descending
entries.sort(key=lambda x: x.get("frequency", 1), reverse=True)

print("Capability Gaps (frekansa gore)")
print("=" * 50)
for e in entries:
    freq = e.get("frequency", 1)
    bar = "█" * min(freq, 20)
    ctx = f" [{e['context']}]" if e.get("context") else ""
    date = e.get("lastSeen", e.get("ts", "?"))[:10]
    print(f"  {freq:>3}x {bar:<20} {e['description']}{ctx} ({date})")

print(f"\nToplam: {len(entries)} gap")
PYEOF
}

cmd_track() {
    local skill="${1:-}"
    local status="${2:-}"
    local duration="${3:-0}"
    local agent="${4:-}"

    if [[ -z "$skill" || -z "$status" ]]; then
        echo "Hata: skill ve status gerekli."
        echo "Kullanim: $0 track <skill> <success|failure> [duration_ms] [agent]"
        exit 1
    fi

    if [[ "$status" != "success" && "$status" != "failure" ]]; then
        echo "Hata: status 'success' veya 'failure' olmali."
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
print(f"Kaydedildi: {skill} — {status}{dur_str}")
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
        # Parse timestamp
        ts_str = entry.get("ts", "")
        try:
            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            if ts >= cutoff:
                entries.append(entry)
        except (ValueError, TypeError):
            entries.append(entry)  # Include if can't parse date

if not entries:
    print("Son 30 gunde metrik yok.")
    sys.exit(0)

# Aggregate by skill
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

print("Skill Performance Report (son 30 gun)")
print("-" * 50)

# Sort by total executions descending
sorted_skills = sorted(skills.items(), key=lambda x: x[1]["success"] + x[1]["failure"], reverse=True)

max_name_len = max(len(name) for name, _ in sorted_skills) if sorted_skills else 15

for name, data in sorted_skills:
    total = data["success"] + data["failure"]
    rate = data["success"] / total * 100 if total > 0 else 0
    bar_width = 10
    filled = int(rate * bar_width / 100)
    bar = "█" * filled + "░" * (bar_width - filled)

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

print(f"\nToplam: {len(sorted_skills)} skill, {sum(s['success']+s['failure'] for _,s in sorted_skills)} calisma")
PYEOF
}

cmd_compose() {
    local name="${1:-}"
    shift || true
    local components=("$@")

    if [[ -z "$name" || ${#components[@]} -lt 2 ]]; then
        echo "Hata: Isim ve en az 2 skill gerekli."
        echo "Kullanim: $0 compose <name> <skill1> <skill2> [skill3...]"
        exit 1
    fi

    # Convert array to JSON-safe format
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

# Check for duplicate name
for c in data.get("compositions", []):
    if c["name"] == name:
        print(f"Hata: '{name}' zaten mevcut.")
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

print(f"Bilesik skill olusturuldu: {name}")
print(f"  Bilesenler: {' + '.join(components)}")
PYEOF
}

cmd_compositions() {
    python3 - "$COMPOSITIONS_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

compositions = data.get("compositions", [])
if not compositions:
    print("Kayitli bilesik skill yok.")
    sys.exit(0)

print("Bilesik Skill Listesi")
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
    print(f"    Bilesenler: {components}")
    print(f"    Kullanim: {count}x | Son: {last}")
    print()

print(f"Toplam: {len(compositions)} bilesik skill")
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

# Analyze
print("Skill Onerileri")
print("=" * 50)

if not gaps:
    print("Kayitli gap yok — gap-log komutuyla eksiklik kaydedin.")
    sys.exit(0)

# Sort by frequency
gaps.sort(key=lambda x: x.get("frequency", 1), reverse=True)

print()
print("1. Oncelikli Gaplar (frekans sirasiyla):")
print("-" * 40)
for g in gaps[:10]:
    freq = g.get("frequency", 1)
    desc = g["description"]
    priority = "YUKSEK" if freq >= 5 else ("ORTA" if freq >= 2 else "DUSUK")
    print(f"  [{priority}] {desc} ({freq}x)")

# Suggest combinations
print()
print("2. Olasi Skill Birlesimleri:")
print("-" * 40)
skill_list = sorted(existing_skills)
suggested_any = False

# Simple keyword matching between gaps and skills
for g in gaps[:5]:
    desc_lower = g["description"].lower()
    matching_skills = []
    for s in skill_list:
        # Check if any word from skill name appears in gap description
        s_words = s.replace("-", " ").replace("_", " ").split()
        for w in s_words:
            if len(w) > 3 and w.lower() in desc_lower:
                matching_skills.append(s)
                break

    if len(matching_skills) >= 2:
        suggested_any = True
        combo = " + ".join(matching_skills[:3])
        print(f"  Gap: \"{g['description']}\"")
        print(f"  Oneri: [{combo}] birlestirilerek cozulebilir")
        print()

if not suggested_any:
    print("  Mevcut skill'lerle otomatik kombinasyon onerisi bulunamadi.")
    print("  Manuel olarak 'compose' komutuyla olusturabilirsiniz.")

# Suggest new standalone skills
print()
print("3. Yeni Skill Onerileri:")
print("-" * 40)
for g in gaps[:5]:
    desc = g["description"]
    freq = g.get("frequency", 1)
    # Generate a slug-style name suggestion
    words = desc.lower().replace(",", "").replace(".", "").split()
    # Filter common words
    stop_words = {"bir", "bu", "ve", "ile", "icin", "olmak", "olmayan", "cannot", "can't",
                  "the", "a", "an", "is", "are", "to", "of", "in", "for", "not", "automatically",
                  "otomatik", "edilemiyor", "yapilamiyor", "sekilde"}
    key_words = [w for w in words if w not in stop_words and len(w) > 2][:3]
    slug = "-".join(key_words) if key_words else "new-skill"

    if slug not in existing_skills and slug not in comp_names:
        print(f"  Oneri: '{slug}' skill'i olusturulmali")
        print(f"    Kaynagi: \"{desc}\" ({freq}x)")
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
    print("4. Sorunlu Skill'ler (>30% basarisizlik):")
    print("-" * 40)
    failing.sort(key=lambda x: x[1], reverse=True)
    for name, rate, total in failing:
        print(f"  {name}: %{rate:.0f} basarisiz ({total} calisma) — iyilestirme veya yeniden yazma onerisi")

print()
PYEOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────
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
    -h|--help|"")   usage ;;
    *)
        echo "Bilinmeyen komut: $cmd"
        usage
        ;;
esac
