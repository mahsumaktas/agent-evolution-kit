# AGENTS.md — Example Agent Configuration

## Architecture

```
                    ┌─────────────┐
                    │ Orchestrator│ ← Never writes code
                    │  (primary)  │
                    └──────┬──────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────┴──────┐ ┌────┴─────┐ ┌──────┴──────┐
     │ researcher  │ │ analyst  │ │  content    │
     │   agent     │ │  agent   │ │   agent     │
     └─────────────┘ └──────────┘ └─────────────┘
```

## Agents

### orchestrator (primary)

**Role:** Pure delegator — routes tasks, monitors performance, runs evolution
**Model:** opus (for strategic decisions)
**Never:** writes code, creates files, modifies config directly

### researcher-agent

**Role:** Web research, information gathering, trend analysis
**Model:** sonnet
**Capabilities:** web search, API queries, source verification
**Maker-Checker:** Checked by analyst-agent

### analyst-agent

**Role:** Data analysis, code review, pattern recognition
**Model:** opus
**Capabilities:** code analysis, data processing, report generation
**Maker-Checker:** Checked by researcher-agent

### content-agent

**Role:** Long-form content, documentation, reports
**Model:** sonnet
**Capabilities:** writing, editing, formatting
**Maker-Checker:** Checked by analyst-agent

## Capability Routing

| Task Type | Primary | Secondary | Fallback |
|-----------|---------|-----------|----------|
| Research | researcher | analyst | bridge |
| Code review | analyst | orchestrator | bridge |
| Content | content | researcher | orchestrator |
| Security | analyst | orchestrator | bridge |

## Evolution Rules

- Each agent has max 10 tactical rules + 5 strategic rules
- Reflexion is MANDATORY after failures
- Weekly evolution cycle: measure → diagnose → prescribe → apply → verify
- Max 1 change per cycle

## Self-Diagnostic

- Check `memory/trajectory-pool.json` for agent performance
- Review `memory/reflections/` for recurring issues
- Monthly: archive old trajectories, prune expired tactical rules
