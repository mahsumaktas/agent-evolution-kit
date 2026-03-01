# Scripts — Agent Evolution Kit

Operational scripts for the Agent Evolution Kit infrastructure. 40+ standalone
Bash utilities implementing monitoring, orchestration, governance, memory,
deployment, and weekly automation cycles.

## Prerequisites

| Requirement | Minimum Version |
|-------------|----------------|
| Bash        | 4.0+           |
| Python 3    | 3.8+           |
| jq          | 1.6+ (optional, Python used as fallback) |
| SQLite 3    | 3.30+          |
| curl        | any            |

## Configuration

Set the `AGENT_HOME` environment variable to point at your kit root directory.
If unset, it defaults to `$HOME/.agent-evolution`.

```bash
export AGENT_HOME="$HOME/.agent-evolution"
```

All scripts read from and write to `$AGENT_HOME/memory/` by default.

## Script Catalog

### Core Infrastructure

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `bridge.sh`         | Nested LLM CLI wrapper with presets       | On-demand             |
| `watchdog.sh`       | 4-tier self-healing process monitor       | Every 60 s (cron/launchd) |
| `metrics.sh`        | SQLite-based metrics collection & reports | On-demand / after tasks |
| `system-check.sh`   | System health monitoring                  | Daily / on-demand     |
| `daily-check.sh`    | Quick daily system health check           | Daily 03:00           |

### Scheduling & Orchestration

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `weekly-cycle.sh`   | Weekly automation orchestrator            | Sunday 22:00          |
| `dag.sh`            | DAG-based workflow execution engine       | On-demand             |
| `cron-audit.sh`     | Crontab audit and anomaly detection       | Weekly Monday 07:00   |
| `cron-watchdog.sh`  | Cron job monitoring and alerting          | Every 5 min           |
| `cron-self-healer.sh`| Auto-repair failed cron jobs             | On-demand / triggered |
| `event-bridge.sh`   | Event routing between system components   | Always-on daemon      |

### Agent Management

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `agent-factory.sh`  | Agent creation and configuration          | On-demand             |
| `agent-health.sh`   | Multi-agent health monitoring (11 agents) | On-demand / periodic  |
| `health-summary.sh` | Aggregated health dashboard               | On-demand             |
| `consciousness.sh`  | Agent self-awareness and state tracking   | On-demand             |
| `shadow-agent.sh`   | Shadow execution for safe testing         | On-demand             |

### Intelligence & Reporting

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `briefing.sh`       | Tri-phase daily status reports            | 08:00 / 13:00 / 21:00 |
| `predict.sh`        | Predictive analysis from trajectory data  | Weekly (Sunday)       |
| `research.sh`       | Autonomous research via LLM bridge        | Weekly / on-demand    |
| `iterative-research.sh` | Multi-round deep research with synthesis | On-demand          |
| `goal-decompose.sh` | HTN-style goal tree management            | On-demand             |
| `skill-discovery.sh`| Capability gap detection & tracking       | On-demand / weekly    |

### Memory & Knowledge

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `memory-index.sh`   | Memory indexing and search                | On-demand             |
| `memory-isolation-test.sh` | Cross-agent memory isolation testing | On-demand          |
| `context-compact.sh`| Context window compaction                 | On-demand             |
| `blackboard.sh`     | Shared blackboard for inter-agent comms   | Always-on             |

### Governance & Quality

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `governance.sh`     | Policy enforcement and compliance checks  | On-demand / triggered |
| `maker-checker.sh`  | Dual-approval workflow for critical ops   | On-demand             |
| `critique.sh`       | Cross-agent critique and review           | On-demand             |
| `circuit-breaker.sh`| Failure detection and circuit breaking    | On-demand             |
| `sandbox.sh`        | 3-layer validation pipeline (L1/L2/L3)   | On-demand             |
| `canary-deploy.sh`  | Canary deployment with auto-rollback      | On-demand             |

### Evolution & Learning

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `evolve-prompt.sh`  | Automated prompt evolution and tuning     | Weekly / on-demand    |
| `eval.sh`           | Evaluation framework for agent performance| On-demand             |
| `replay.sh`         | Record & replay for task reproduction     | On-demand             |
| `swarm.sh`          | Multi-agent swarm coordination patterns   | On-demand             |
| `tool-gen.sh`       | Automated tool generation pipeline        | On-demand             |
| `self-improving-agent.sh` | Self-improvement cycle execution    | On-demand             |

### Browser & Web

| Script              | Purpose                                   | Typical Schedule      |
|---------------------|-------------------------------------------|-----------------------|
| `parallel-browser.sh` | Parallel browser automation (multi-tab) | On-demand             |
| `spa-navigator.sh`  | SPA navigation and interaction            | On-demand             |
| `captcha-solver.sh` | Captcha solving with multiple strategies  | On-demand             |

## Quick Start

1. **Set environment:**
   ```bash
   export AGENT_HOME="$HOME/.agent-evolution"
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
   0 8 * * *   /path/to/scripts/briefing.sh morning
   0 13 * * *  /path/to/scripts/briefing.sh midday
   0 21 * * *  /path/to/scripts/briefing.sh evening
   ```

5. **Set up weekly cycle:**
   ```cron
   0 22 * * 0  /path/to/scripts/weekly-cycle.sh
   ```

6. **Run a DAG workflow:**
   ```bash
   ./scripts/dag.sh run workflows/morning-routine.json
   ```

## Directory Structure

Scripts expect (and create) the following directories under `$AGENT_HOME`:

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
  blackboard/             # Shared inter-agent state
skills/
  compositions.json       # Composite skill registry
workflows/
  *.json                  # DAG workflow definitions
```

## Notes

- All scripts use `set -euo pipefail` for safety.
- Colored output is used for terminal feedback; pipe to a file if you need plain text.
- The `bridge.sh` script requires an LLM CLI tool (e.g., Claude CLI) in your PATH.
- The `watchdog.sh` script supports both `launchctl` (macOS) and `systemctl` (Linux).
- Each script includes a `--help` flag for detailed usage information.
- The `governance.sh` script enforces configurable policies via YAML rule definitions.
- The `dag.sh` engine supports parallel execution, dependencies, and retry logic.
