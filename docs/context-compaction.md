# Context Compaction

Memory grows without bound. Trajectory pools accumulate entries, bridge logs pile
up, reflections duplicate, and knowledge files go stale. Context compaction is the
automated cleanup system that keeps memory lean without losing important information.

## Problem

LLM agents generate significant amounts of persistent data: trajectory records,
bridge execution logs, reflection files, knowledge documents, predictions, and
briefings. Without active management:

- Trajectory pools exceed practical sizes for context injection.
- Bridge log directories consume disk space with diminishing diagnostic value.
- Reflection files contain near-duplicate entries from similar failure patterns.
- Knowledge files in hot/warm tiers become stale but are never demoted.

## Architecture

The compaction system is a 5-stage pipeline, each stage targeting a different
memory category:

| Stage | Target | Strategy | Threshold |
|-------|--------|----------|-----------|
| 1 | Trajectory pool | Keep recent 50, archive older | 50 entries |
| 2 | Bridge logs | Keep 14 days, archive older | 14 days |
| 3 | Reflections | Jaccard deduplication (0.75 threshold) | 3+ files per agent |
| 4 | Knowledge | Importance scoring, demote low-scoring | Score < 30 (hot), < 20 (warm) |
| 5 | Dated directories | Archive old predictions (30d) and briefings (60d) | Age-based |

### Stage 1: Trajectory Compaction

The trajectory pool (`memory/trajectory-pool.json`) is the most frequently written
memory file. Stage 1 keeps the 50 most recent entries in the active pool and moves
older entries to `memory/archive/trajectory-YYYY-MM.json`. Monthly archive files
are append-only.

### Stage 2: Bridge Log Archival

Bridge execution logs older than 14 days are moved from `memory/bridge-logs/` to
`memory/archive/bridge-logs/`. Recent logs are kept for debugging; older logs
retain archival value but do not need fast access.

### Stage 3: Reflection Deduplication

When agents fail in similar ways, their reflections are often near-identical. Stage
3 uses Jaccard word-set similarity (threshold: 0.75) to identify duplicate
reflections within each agent's reflection directory. Duplicates are moved to
`memory/archive/reflections/<agent>/`.

### Stage 4: Knowledge Demotion

Knowledge files in `hot/` and `warm/` tiers are scored using a 4-channel importance
scorer:

- **Recency** (25%): Newer files score higher.
- **Role** (25%): System and assistant content scores higher than tool output.
- **Content** (30%): Files containing high-importance keywords (error, critical,
  decision, security, architecture, etc.) score higher.
- **Access** (20%): Frequently accessed files score higher.

Files scoring below the threshold and older than 30 days are demoted to `cold/`.

### Stage 5: Dated Directory Cleanup

Predictions older than 30 days and briefings older than 60 days are archived.

## Modes

### Weekly Mode (`--weekly`)

Runs all 5 stages. This is the default mode for the weekly evolution cycle.

### Pre-bridge Mode (`--pre-compact`)

Runs only Stage 1 (trajectory compaction). Lightweight, suitable for running before
every bridge call to keep trajectory context manageable.

### Post-bridge Mode (`--post-compact`)

Runs only Stage 2 (bridge log archival). Cleans up after bridge execution.

### Stats Mode (`--stats`)

Shows current memory usage by directory, estimated token counts, and detected
compaction opportunities. Does not modify any files.

### Dry Run (`--dry-run`)

Can be combined with any mode. Shows what actions would be taken without executing
them.

## Usage

```bash
# Show memory stats and compaction opportunities
scripts/context-compact.sh --stats

# Preview weekly compaction without changes
scripts/context-compact.sh --weekly --dry-run

# Run full weekly compaction
scripts/context-compact.sh --weekly

# Lightweight pre-bridge compaction
scripts/context-compact.sh --pre-compact

# Post-bridge log cleanup
scripts/context-compact.sh --post-compact
```

### Direct Python Usage

```bash
python3 scripts/helpers/context-compactor.py --memory-dir memory/ --stats
python3 scripts/helpers/context-compactor.py --memory-dir memory/ --weekly --dry-run
```

## Integration

### Weekly Cycle

The weekly evolution cycle (`scripts/weekly-cycle.sh`) includes context compaction
as one of its steps. It runs the `--weekly` mode automatically.

### Token Estimation

The stats mode estimates token counts using a heuristic: `file_size / 4` for text
files, with a 1.5x multiplier for code files (`.py`, `.js`, `.ts`, `.sh`, `.json`,
`.yaml`). This is an approximation, not an exact tokenizer count.

## Configuration

The compaction thresholds are currently hardcoded in the Python implementation:

| Parameter | Value | Description |
|-----------|-------|-------------|
| Trajectory keep count | 50 | Entries to keep in active pool |
| Bridge log retention | 14 days | Days to keep bridge logs |
| Jaccard threshold | 0.75 | Similarity threshold for dedup |
| Hot knowledge threshold | 30 | Score below which hot files are demoted |
| Warm knowledge threshold | 20 | Score below which warm files are demoted |
| Knowledge min age | 30 days | Minimum age before demotion |
| Prediction retention | 30 days | Days to keep predictions |
| Briefing retention | 60 days | Days to keep briefings |

To customize, edit `scripts/helpers/context-compactor.py` directly.
