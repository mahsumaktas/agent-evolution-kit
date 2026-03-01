# Scripts — Agent Evolution Kit

Operational scripts for the Agent Evolution Kit infrastructure. These are
standalone Bash utilities that implement monitoring, metrics, goal tracking,
skill discovery, and weekly automation cycles.

## Prerequisites

| Requirement | Minimum Version |
|-------------|----------------|
| Bash        | 4.0+           |
| Python 3    | 3.8+           |
| jq          | 1.6+ (optional, Python used as fallback) |
| SQLite 3    | 3.30+          |
| curl        | any            |

## Configuration

Set the `AEK_HOME` environment variable to point at your kit root directory.
If unset, it defaults to `$HOME/agent-evolution-kit`.

```bash
export AEK_HOME="$HOME/agent-evolution-kit"
```

All scripts read from and write to `$AEK_HOME/memory/` by default.

## Script Overview

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `bridge.sh`         | Nested LLM CLI wrapper with presets       | On-demand             |
| `watchdog.sh`       | 4-tier self-healing process monitor       | Every 60 s (cron/launchd) |
| `metrics.sh`        | SQLite-based metrics collection & reports | On-demand / after tasks |
| `briefing.sh`       | Tri-phase daily status reports            | 08:00 / 13:00 / 21:00 |
| `goal-decompose.sh` | HTN-style goal tree management            | On-demand             |
| `skill-discovery.sh`| Capability gap detection & tracking       | On-demand / weekly    |
| `predict.sh`        | Predictive analysis from trajectory data  | Weekly (Sunday)       |
| `research.sh`       | Autonomous research via LLM bridge        | Weekly / on-demand    |
| `system-check.sh`   | System health monitoring                  | Daily / on-demand     |
| `weekly-cycle.sh`   | Weekly automation orchestrator            | Sunday 22:00          |

## Quick Start

1. **Set environment:**
   ```bash
   export AEK_HOME="$HOME/agent-evolution-kit"
   ```

2. **Initialize metrics database:**
   ```bash
   ./scripts/metrics.sh init
   ```

3. **Run a system check:**
   ```bash
   ./scripts/system-check.sh --full
   ```

4. **Set up daily briefings (crontab example):**
   ```cron
   0 8 * * *   /path/to/agent-evolution-kit/scripts/briefing.sh morning
   0 13 * * *  /path/to/agent-evolution-kit/scripts/briefing.sh midday
   0 21 * * *  /path/to/agent-evolution-kit/scripts/briefing.sh evening
   ```

5. **Set up weekly cycle:**
   ```cron
   0 22 * * 0  /path/to/agent-evolution-kit/scripts/weekly-cycle.sh
   ```

## Directory Structure

Scripts expect (and create) the following directories under `$AEK_HOME`:

```
memory/
  metrics.db              # SQLite metrics database
  briefings/              # Daily briefing reports
  goals/                  # Goal tree JSON files
  knowledge/              # Research findings
  predictions/            # Prediction reports
  trajectory-pool.json    # Task execution history
  evolution-log.md        # Weekly cycle log
  bridge-logs/            # LLM bridge call logs
  cost-log.jsonl          # Append-only cost ledger
  skill-gaps.jsonl        # Capability gap log
  skill-metrics.jsonl     # Skill usage tracking
skills/
  compositions.json       # Composite skill registry
```

## Notes

- All scripts use `set -euo pipefail` for safety.
- Colored output is used for terminal feedback; pipe to a file if you need plain text.
- The `bridge.sh` script requires an LLM CLI tool (e.g., Claude CLI) in your PATH.
- The `watchdog.sh` script supports both `launchctl` (macOS) and `systemctl` (Linux).
- Each script includes a `--help` flag for detailed usage information.
