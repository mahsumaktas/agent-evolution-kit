#!/usr/bin/env python3
"""Agent Evolution Kit — Context Compactor — Memory compaction engine.

Modes:
  --pre-compact     Before bridge call: compact trajectory context
  --post-compact    After bridge: archive successful runs
  --weekly          Deep compaction: all memory dirs
  --stats           Show current memory usage and compaction opportunities
  --dry-run         Show what would be done without doing it

Usage:
  python3 context-compactor.py --stats --memory-dir ~/agent-evolution-kit/memory
  python3 context-compactor.py --weekly --dry-run --memory-dir ~/agent-evolution-kit/memory
  python3 context-compactor.py --weekly --memory-dir ~/agent-evolution-kit/memory
"""

import argparse
import json
import os
import re
import shutil
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path


class TokenEstimator:
    """Estimate token count from text. Heuristic: len(text) // 4, code gets 1.5x multiplier."""

    CODE_EXTENSIONS = {'.py', '.js', '.ts', '.sh', '.bash', '.json', '.yaml', '.yml'}

    @staticmethod
    def estimate(text: str, is_code: bool = False) -> int:
        base = len(text) // 4
        return int(base * 1.5) if is_code else base

    @staticmethod
    def estimate_file(filepath: str) -> int:
        ext = os.path.splitext(filepath)[1].lower()
        is_code = ext in TokenEstimator.CODE_EXTENSIONS
        try:
            size = os.path.getsize(filepath)
            base = size // 4
            return int(base * 1.5) if is_code else base
        except OSError:
            return 0


class ImportanceScorer:
    """Score importance of a memory entry using 4 channels."""

    # Weights sum to 1.0
    WEIGHTS = {
        'recency': 0.25,
        'role': 0.25,
        'content': 0.30,
        'access': 0.20,
    }

    ROLE_SCORES = {
        'assistant': 0.9,
        'user': 0.7,
        'system': 1.0,
        'tool': 0.5,
    }

    HIGH_IMPORTANCE_KEYWORDS = [
        'error', 'critical', 'decision', 'risk', 'security', 'fix', 'bug',
        'principle', 'lesson', 'important', 'never', 'always', 'must',
        'architecture', 'design', 'breaking', 'migration'
    ]

    def score(self, entry: dict, now: datetime = None) -> float:
        """Return importance score 0-100."""
        if now is None:
            now = datetime.now()

        # Channel 1: Recency (newer = more important)
        ts = entry.get('timestamp', '')
        try:
            entry_time = datetime.fromisoformat(
                ts.replace('Z', '+00:00').replace('+00:00', '')
            )
        except (ValueError, AttributeError):
            entry_time = now - timedelta(days=90)
        age_days = (now - entry_time).days

        recency = max(0, 1.0 - (age_days / 90))

        # Channel 2: Role importance
        role = entry.get('role', entry.get('agent', 'tool'))
        role_score = self.ROLE_SCORES.get(role, 0.5)

        # Channel 3: Content importance (keyword matching)
        content = json.dumps(entry, default=str).lower()
        keyword_hits = sum(1 for kw in self.HIGH_IMPORTANCE_KEYWORDS if kw in content)
        content_score = min(1.0, keyword_hits / 3)  # 3+ hits = max score

        # Channel 4: Access frequency
        access_count = entry.get('access_count', entry.get('turns', 1))
        access_score = min(1.0, access_count / 10)  # 10+ accesses = max score

        # Weighted combination
        total = (
            recency * self.WEIGHTS['recency']
            + role_score * self.WEIGHTS['role']
            + content_score * self.WEIGHTS['content']
            + access_score * self.WEIGHTS['access']
        )

        return round(total * 100, 1)


class JaccardDeduplicator:
    """Deduplicate entries using Jaccard word-set similarity."""

    def __init__(self, threshold: float = 0.75):
        self.threshold = threshold

    @staticmethod
    def _word_set(text: str) -> set:
        return set(re.findall(r'\w+', text.lower()))

    @staticmethod
    def _jaccard_sets(set_a: set, set_b: set) -> float:
        """Compute Jaccard similarity from pre-computed word sets."""
        if not set_a or not set_b:
            return 0.0
        intersection = set_a & set_b
        union = set_a | set_b
        return len(intersection) / len(union) if union else 0.0

    def similarity(self, text_a: str, text_b: str) -> float:
        set_a = self._word_set(text_a)
        set_b = self._word_set(text_b)
        return self._jaccard_sets(set_a, set_b)

    def deduplicate(self, entries: list, key_fn=None) -> tuple:
        """Return (kept, removed) lists. key_fn extracts text from entry."""
        if key_fn is None:
            key_fn = lambda e: json.dumps(e, default=str)

        kept = []
        kept_indices = []
        removed = []

        # Pre-compute word sets for all entries
        word_sets = []
        for entry in entries:
            text = key_fn(entry)
            word_sets.append(self._word_set(text))

        for i, entry in enumerate(entries):
            is_dup = False
            for kept_idx in kept_indices:
                if self._jaccard_sets(word_sets[i], word_sets[kept_idx]) >= self.threshold:
                    is_dup = True
                    removed.append(entry)
                    break
            if not is_dup:
                kept.append(entry)
                kept_indices.append(i)

        return kept, removed


class ContextCompactor:
    """5-stage compaction engine."""

    def __init__(self, memory_dir: str, dry_run: bool = False):
        self.memory_dir = Path(memory_dir)
        self.dry_run = dry_run
        self.scorer = ImportanceScorer()
        self.dedup = JaccardDeduplicator(threshold=0.75)
        self.estimator = TokenEstimator()
        self.actions = []  # Log of actions taken

    def _log(self, action: str, detail: str):
        self.actions.append({'action': action, 'detail': detail})
        print(f"  {'[DRY] ' if self.dry_run else ''}{action}: {detail}")

    # --- Stage 1: Trajectory ---

    def compact_trajectory(self):
        """Compact trajectory-pool.json: keep 50 recent, archive older."""
        traj_file = self.memory_dir / 'trajectory-pool.json'
        if not traj_file.exists():
            return

        with open(traj_file) as f:
            data = json.load(f)

        if isinstance(data, dict):
            entries = data.get('entries', [])
            meta = {k: v for k, v in data.items() if k != 'entries'}
        else:
            entries = data
            meta = {}

        if len(entries) <= 50:
            self._log('skip', f'trajectory: {len(entries)} entries (<=50, no action)')
            return

        # Archive older entries
        archive_dir = self.memory_dir / 'archive'
        archive_dir.mkdir(parents=True, exist_ok=True)
        month = datetime.now().strftime('%Y-%m')
        archive_file = archive_dir / f'trajectory-{month}.json'

        to_archive = entries[:-50]
        to_keep = entries[-50:]

        self._log(
            'archive',
            f'trajectory: {len(to_archive)} entries -> archive/trajectory-{month}.json'
        )

        if not self.dry_run:
            # Append to existing archive
            existing_archive = []
            if archive_file.exists():
                try:
                    with open(archive_file) as f:
                        existing_archive = json.load(f)
                except json.JSONDecodeError:
                    existing_archive = []

            if isinstance(existing_archive, dict):
                existing_archive = existing_archive.get('entries', [])

            existing_archive.extend(to_archive)
            with open(archive_file, 'w') as f:
                json.dump(existing_archive, f, indent=2, ensure_ascii=False)

            # Update trajectory
            output = {**meta, 'entries': to_keep} if meta else to_keep
            with open(traj_file, 'w') as f:
                json.dump(output, f, indent=2, ensure_ascii=False)

    # --- Stage 2: Bridge Logs ---

    def compact_bridge_logs(self):
        """Keep 14 days of bridge logs, archive older."""
        log_dir = self.memory_dir / 'bridge-logs'
        if not log_dir.exists():
            return

        cutoff = datetime.now() - timedelta(days=14)
        archive_dir = self.memory_dir / 'archive' / 'bridge-logs'

        old_files = []
        for f in log_dir.glob('*.json'):
            try:
                mtime = datetime.fromtimestamp(f.stat().st_mtime)
                if mtime < cutoff:
                    old_files.append(f)
            except OSError:
                continue

        if not old_files:
            self._log('skip', 'bridge-logs: all files within 14 days')
            return

        self._log('archive', f'bridge-logs: {len(old_files)} old files')

        if not self.dry_run:
            archive_dir.mkdir(parents=True, exist_ok=True)
            for f in old_files:
                dest = archive_dir / f.name
                shutil.move(str(f), str(dest))

    # --- Stage 3: Reflections ---

    def compact_reflections(self):
        """Deduplicate similar reflections, keep unique patterns."""
        reflect_dir = self.memory_dir / 'reflections'
        if not reflect_dir.exists():
            return

        for agent_dir in reflect_dir.iterdir():
            if not agent_dir.is_dir():
                continue

            md_files = sorted(agent_dir.glob('*.md'), key=lambda f: f.stat().st_mtime)
            if len(md_files) <= 3:
                continue

            # Read contents
            entries = []
            for f in md_files:
                try:
                    content = f.read_text(encoding='utf-8', errors='replace')
                    entries.append({'path': str(f), 'content': content, 'file': f})
                except OSError:
                    continue

            kept, removed = self.dedup.deduplicate(
                entries, key_fn=lambda e: e['content']
            )

            if removed:
                self._log(
                    'dedup',
                    f'reflections/{agent_dir.name}: {len(removed)} duplicates'
                )
                if not self.dry_run:
                    dedup_archive = (
                        self.memory_dir / 'archive' / 'reflections' / agent_dir.name
                    )
                    dedup_archive.mkdir(parents=True, exist_ok=True)
                    for entry in removed:
                        dest = dedup_archive / Path(entry['path']).name
                        shutil.move(entry['path'], str(dest))

    # --- Stage 4: Knowledge ---

    def compact_knowledge(self):
        """Score knowledge files, move low-scoring to cold/."""
        for tier in ['hot', 'warm']:
            tier_dir = self.memory_dir / 'knowledge' / tier
            if not tier_dir.exists():
                continue

            cold_dir = self.memory_dir / 'knowledge' / 'cold'

            for f in tier_dir.glob('*.md'):
                try:
                    with open(f, 'r', encoding='utf-8', errors='replace') as fh:
                        content = fh.read(500)
                    mtime = datetime.fromtimestamp(f.stat().st_mtime)
                    age_days = (datetime.now() - mtime).days

                    # Simple scoring: age + content keywords
                    score = self.scorer.score({
                        'timestamp': mtime.isoformat(),
                        'content': content,
                        'access_count': 1,
                    })

                    threshold = 30 if tier == 'hot' else 20
                    if score < threshold and age_days > 30:
                        self._log(
                            'demote',
                            f'knowledge/{tier}/{f.name} (score={score:.0f})'
                        )
                        if not self.dry_run:
                            cold_dir.mkdir(parents=True, exist_ok=True)
                            shutil.move(str(f), str(cold_dir / f.name))
                except OSError:
                    continue

    # --- Stage 5: Dated Directories ---

    def compact_dated_dirs(self):
        """Archive old predictions and briefings."""
        targets = [
            ('predictions', 30),
            ('briefings', 60),
        ]

        for dirname, max_days in targets:
            dir_path = self.memory_dir / dirname
            if not dir_path.exists():
                continue

            cutoff = datetime.now() - timedelta(days=max_days)
            archive_dir = self.memory_dir / 'archive' / dirname

            old_files = []
            for f in dir_path.iterdir():
                if f.is_file():
                    try:
                        mtime = datetime.fromtimestamp(f.stat().st_mtime)
                        if mtime < cutoff:
                            old_files.append(f)
                    except OSError:
                        continue

            if old_files:
                self._log(
                    'archive',
                    f'{dirname}: {len(old_files)} files older than {max_days}d'
                )
                if not self.dry_run:
                    archive_dir.mkdir(parents=True, exist_ok=True)
                    for f in old_files:
                        shutil.move(str(f), str(archive_dir / f.name))

    # --- Stats ---

    def stats(self):
        """Show current memory usage."""
        print(f"\n{'=' * 60}")
        print("Context Compactor — Memory Stats")
        print(f"{'=' * 60}")
        print(f"Memory dir: {self.memory_dir}")
        print()

        total_tokens = 0
        total_files = 0

        # Walk memory dir
        dir_stats = defaultdict(lambda: {'files': 0, 'size': 0, 'tokens': 0})

        for root, dirs, files in os.walk(self.memory_dir):
            # Skip .git and archive
            dirs[:] = [d for d in dirs if d not in {'.git', 'archive', 'node_modules'}]

            rel_root = os.path.relpath(root, self.memory_dir)
            top_dir = rel_root.split(os.sep)[0] if rel_root != '.' else '.'

            for fname in files:
                fpath = os.path.join(root, fname)
                try:
                    size = os.path.getsize(fpath)
                    tokens = self.estimator.estimate_file(fpath)
                    dir_stats[top_dir]['files'] += 1
                    dir_stats[top_dir]['size'] += size
                    dir_stats[top_dir]['tokens'] += tokens
                    total_tokens += tokens
                    total_files += 1
                except OSError:
                    continue

        # Print table
        print(
            f"{'Directory':<25} {'Files':>6} {'Size':>10} {'~Tokens':>10}"
        )
        print('-' * 55)
        for dirname, st in sorted(dir_stats.items(), key=lambda x: -x[1]['tokens']):
            size_str = self._human_size(st['size'])
            print(f"{dirname:<25} {st['files']:>6} {size_str:>10} {st['tokens']:>10,}")

        total_size = sum(s['size'] for s in dir_stats.values())
        print('-' * 55)
        print(
            f"{'TOTAL':<25} {total_files:>6} "
            f"{self._human_size(total_size):>10} {total_tokens:>10,}"
        )
        print()

        # Compaction opportunities
        print("Compaction Opportunities:")
        found_opportunity = False

        # Trajectory
        traj = self.memory_dir / 'trajectory-pool.json'
        if traj.exists():
            try:
                with open(traj) as f:
                    data = json.load(f)
                entries = data.get('entries', data) if isinstance(data, dict) else data
                if isinstance(entries, list) and len(entries) > 50:
                    print(
                        f"  - trajectory: {len(entries)} entries "
                        f"(>50, can archive {len(entries) - 50})"
                    )
                    found_opportunity = True
            except (json.JSONDecodeError, OSError):
                pass

        # Old bridge logs
        log_dir = self.memory_dir / 'bridge-logs'
        if log_dir.exists():
            cutoff = datetime.now() - timedelta(days=14)
            old = 0
            for f in log_dir.glob('*.json'):
                try:
                    if datetime.fromtimestamp(f.stat().st_mtime) < cutoff:
                        old += 1
                except OSError:
                    continue
            if old:
                print(f"  - bridge-logs: {old} files older than 14 days")
                found_opportunity = True

        # Old briefings
        brief_dir = self.memory_dir / 'briefings'
        if brief_dir.exists():
            cutoff = datetime.now() - timedelta(days=60)
            old = 0
            for f in brief_dir.iterdir():
                if f.is_file():
                    try:
                        if datetime.fromtimestamp(f.stat().st_mtime) < cutoff:
                            old += 1
                    except OSError:
                        continue
            if old:
                print(f"  - briefings: {old} files older than 60 days")
                found_opportunity = True

        if not found_opportunity:
            print("  (none detected)")

        print()

    @staticmethod
    def _human_size(nbytes: int) -> str:
        for unit in ('B', 'KB', 'MB', 'GB'):
            if abs(nbytes) < 1024:
                return f"{nbytes:.1f}{unit}"
            nbytes /= 1024
        return f"{nbytes:.1f}TB"

    # --- Run Modes ---

    def run_weekly(self):
        """Full weekly compaction."""
        print("Context Compaction — Weekly Mode")
        print('=' * 40)
        self.compact_trajectory()
        self.compact_bridge_logs()
        self.compact_reflections()
        self.compact_knowledge()
        self.compact_dated_dirs()
        print(f"\nTotal actions: {len(self.actions)}")

    def run_pre(self):
        """Pre-bridge compaction (lightweight)."""
        print("Context Compaction — Pre-bridge")
        self.compact_trajectory()

    def run_post(self):
        """Post-bridge compaction."""
        print("Context Compaction — Post-bridge")
        self.compact_bridge_logs()


def main():
    parser = argparse.ArgumentParser(description='Context Compactor — Memory compaction engine')
    parser.add_argument(
        '--memory-dir', required=True, help='Path to memory directory'
    )
    parser.add_argument(
        '--pre-compact', action='store_true',
        help='Pre-bridge lightweight compaction'
    )
    parser.add_argument(
        '--post-compact', action='store_true',
        help='Post-bridge compaction'
    )
    parser.add_argument(
        '--weekly', action='store_true',
        help='Full weekly deep compaction'
    )
    parser.add_argument(
        '--stats', action='store_true',
        help='Show memory stats'
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Show actions without executing'
    )

    args = parser.parse_args()

    if not os.path.isdir(args.memory_dir):
        print(f"Error: {args.memory_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    compactor = ContextCompactor(args.memory_dir, dry_run=args.dry_run)

    if args.stats:
        compactor.stats()
    elif args.weekly:
        compactor.run_weekly()
    elif args.pre_compact:
        compactor.run_pre()
    elif args.post_compact:
        compactor.run_post()
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()
