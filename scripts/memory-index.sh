#!/usr/bin/env bash
# memory-index.sh — Memory dizinini tarar, index.json uretir
# Kullanim: ./memory-index.sh

set -euo pipefail

MEMORY_DIR="~/.agent-evolution/memory"
OUTPUT="$MEMORY_DIR/index.json"

python3 - "$MEMORY_DIR" "$OUTPUT" << 'PYEOF'
import sys
import os
import json
import re
from datetime import datetime, timezone, timedelta

MEMORY_DIR = sys.argv[1]
OUTPUT = sys.argv[2]

EXTENSIONS = {".md", ".json", ".jsonl"}

# --- Domain detection ---

DOMAIN_PATH_MAP = {
    "archive/": "archive",
    "projects/": "projects",
    "people/": "people",
    "decisions/": "decisions",
    "knowledge/": "knowledge",
    "research-findings/": "research-findings",
    "learnings/": "knowledge",
    "distilled/": "knowledge",
    "reference/": "knowledge",
    "reflections/": "oracle",
    "predictions/": "oracle",
    "weekly-reviews/": "daily-notes",
    "bridge-logs/": "system",
    "clusters/": "system",
    "conversations/": "archive",
}

DOMAIN_CONTENT_KEYWORDS = {
    "finance": ["finans", "finance", "gelir", "gider", "butce", "maaş", "maas", "odeme", "fatura", "para", "yatirim", "kredi"],
    "health": ["saglik", "health", "randevu", "doktor", "ilac", "appointment", "hospital"],
    "research": ["research", "arastirma", "analiz", "bulgu", "finding"],
    "system": ["cron", "gateway", "heartbeat", "restart", "launchctl", "config", "setup", "maintenance", "bakim"],
    "oracle": ["oracle", "prediction", "reflection", "tahmin", "ongoru"],
}

DATE_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})")


def detect_domain(rel_path, first_line):
    """Path ve icerik bazli domain tespiti."""
    rel_lower = rel_path.lower()

    # Path-based detection (en guvenilir)
    for prefix, domain in DOMAIN_PATH_MAP.items():
        if rel_lower.startswith(prefix):
            return domain

    # Root-level tarihli dosyalar -> daily-notes
    basename = os.path.basename(rel_path)
    if DATE_PATTERN.match(basename):
        return "daily-notes"

    # Content keyword detection
    check_text = (first_line or "").lower() + " " + rel_lower
    for domain, keywords in DOMAIN_CONTENT_KEYWORDS.items():
        for kw in keywords:
            if kw in check_text:
                return domain

    # Specific file mapping
    specific = {
        "health-appointments.md": "health",
        "networking-strategy.md": "people",
        "twitter-persona.md": "projects",
        "tool-radar.md": "knowledge",
        "ai-knowledge-base.md": "knowledge",
        "blog-style-notes.md": "knowledge",
        "evolution-log.md": "oracle",
        "idea-bank.md": "projects",
        "notion-property-specs.md": "system",
        "trajectory-pool.json": "oracle",
        "context-buffer.md": "system",
        "email-triage-last-run.md": "system",
        "research-log.md": "research",
    }
    if basename in specific:
        return specific[basename]

    return "system"


def detect_importance(rel_path, mtime_ts):
    """Path ve recency bazli importance tespiti."""
    rel_lower = rel_path.lower()

    # Path-based rules
    if rel_lower.startswith("archive/"):
        return "low"
    if rel_lower.startswith("reference/") or rel_lower.startswith("distilled/"):
        return "high"
    if rel_lower.startswith("decisions/"):
        return "high"

    # Recency: son 3 gun = high, son 7 gun = medium, geri kalan = low
    now = datetime.now(timezone.utc)
    mtime = datetime.fromtimestamp(mtime_ts, tz=timezone.utc)
    age_days = (now - mtime).days

    if age_days <= 3:
        return "high"
    elif age_days <= 7:
        return "medium"
    else:
        return "low"


def get_first_line(filepath):
    """Dosyanin ilk bos olmayan satirini dondurur."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if stripped:
                    # Markdown heading prefix'ini temizle
                    cleaned = re.sub(r"^#+\s*", "", stripped)
                    return cleaned[:200]  # max 200 char
        return ""
    except Exception:
        return ""


def scan_memory(memory_dir):
    """Memory dizinini recursive tarar."""
    files = []
    for root, dirs, filenames in os.walk(memory_dir):
        # index.json'u atla (kendi ciktimiz)
        for fname in filenames:
            if fname == "index.json" and root == memory_dir:
                continue
            ext = os.path.splitext(fname)[1].lower()
            if ext not in EXTENSIONS:
                continue
            # Gizli dosyalari da dahil et (orn. .state.json)
            full_path = os.path.join(root, fname)
            rel_path = os.path.relpath(full_path, memory_dir)

            try:
                stat = os.stat(full_path)
            except OSError:
                continue

            first_line = get_first_line(full_path) if ext in {".md", ".jsonl"} else ""
            if ext == ".json":
                # JSON icin dosya adini title olarak kullan
                first_line = fname

            domain = detect_domain(rel_path, first_line)
            importance = detect_importance(rel_path, stat.st_mtime)

            mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )

            files.append({
                "path": rel_path,
                "size_bytes": stat.st_size,
                "last_modified": mtime_iso,
                "first_line": first_line,
                "domain": domain,
                "importance": importance,
            })

    return files


def main():
    files = scan_memory(MEMORY_DIR)

    # Sort: domain asc, then path asc
    files.sort(key=lambda f: (f["domain"], f["path"]))

    # Domain summary
    domain_counts = {}
    for f in files:
        d = f["domain"]
        domain_counts[d] = domain_counts.get(d, 0) + 1

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    index = {
        "_generated": now_iso,
        "_total_files": len(files),
        "_domains": dict(sorted(domain_counts.items())),
        "files": files,
    }

    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)

    print(f"Index generated: {OUTPUT}")
    print(f"Total files: {len(files)}")
    print("Domains:")
    for d, c in sorted(domain_counts.items()):
        print(f"  {d}: {c}")


if __name__ == "__main__":
    main()
PYEOF
