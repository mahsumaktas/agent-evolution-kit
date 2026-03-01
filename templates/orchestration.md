# Orchestration Configuration Template

> Copy this to your project and customize to define your multi-agent orchestration rules.

## Agent Registry

| Agent | Role | Model | Schedule |
|-------|------|-------|----------|
| [agent-1] | [role] | [model] | [on-demand/cron] |
| [agent-2] | [role] | [model] | [on-demand/cron] |
| [agent-3] | [role] | [model] | [on-demand/cron] |

## Delegation Modes

Agents operate in two modes:

| Mode | When | Example |
|------|------|---------|
| **Cron** | Scheduled, recurring tasks | Daily report, health check |
| **Tool** | On-demand, orchestrator-initiated | "Analyze this", "Research that" |

**Rule:** In tool mode, results ALWAYS return to orchestrator. Agent never responds directly to operator.

## Orchestrator Constraints

The orchestrator is a pure delegator:

| Action | Allowed | Mechanism |
|--------|---------|-----------|
| Read files, run scripts | YES | Direct |
| System info queries | YES | Direct |
| Write/create files | NO | Delegate to subagent |
| Edit files | NO | Delegate to subagent |
| Write code | NO | Delegate to subagent |

## Routing Matrix

| Capability | Primary Agent | Secondary | Fallback |
|-----------|--------------|-----------|----------|
| [capability-1] | [agent-1] | [agent-2] | bridge |
| [capability-2] | [agent-2] | [agent-3] | bridge |

## Evolution Schedule

| Time | Action | Script |
|------|--------|--------|
| Daily | Trajectory recording | Automatic |
| Daily | Reflexion after failures | Automatic |
| Weekly | Evolution cycle | weekly-cycle.sh |
| Weekly | Research | research.sh --auto |
| Weekly | Prediction | predict.sh --weekly |
| Monthly | Strategic rule review | Manual |
| Quarterly | Full system review | Manual |

## Consensus Protocol

For research findings requiring verification:

```
RETRIEVE: Agent brings finding
VERIFY:   Orchestrator cross-checks with independent source
SYNTHESIZE: Verified info presented to operator
```

**Rules:**
- Unverified info NEVER presented to operator as fact
- Single source insufficient — minimum 2 independent sources
- "Could not verify" is acceptable — "made up" is not

## Cross-Agent Critique Matrix

| Producer | Reviewer | Focus |
|----------|----------|-------|
| [agent-1] | [agent-2] | [what to check] |
| [agent-2] | [agent-3] | [what to check] |

**Trigger:** Top 3 most important weekly tasks + orchestrator discretion.
**Never:** Routine/automated tasks.

---

*This template covers the essential orchestration configuration. See `docs/architecture.md` for the complete 25-section reference.*
