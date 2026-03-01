# Shadow Agent

Observer pattern for automated agent monitoring. A shadow agent watches other agents
work and flags issues without interfering with their execution. Think of it as a
code reviewer that works in the background on every significant action.

## Overview

Agents make mistakes that they cannot catch themselves. A shadow agent operates as
an independent observer: it receives copies of agent actions and outputs, evaluates
them against configurable criteria, and either logs observations silently, adds review
comments, or actively intervenes. The key constraint is that shadow agents never
block the primary agent's workflow in passive or review mode.

## Modes

### Passive Mode

The shadow agent observes and logs but never intervenes. All observations are written
to a log file for later analysis.

**Use case:** Baseline monitoring during the first weeks of deployment. Understand
what the shadow agent would flag before enabling active intervention.

### Review Mode

The shadow agent adds review comments to agent outputs. Comments are visible to the
orchestrator and appear in the trajectory pool, but do not block execution.

**Use case:** Production monitoring where you want insights without disruption. The
orchestrator can incorporate shadow feedback in future task routing decisions.

### Active Mode

The shadow agent can reject outputs and trigger re-evaluation. This is the most
disruptive mode and should only be used for high-risk domains.

**Use case:** Security-critical workflows, financial transactions, or any domain
where catching an error post-hoc is significantly more expensive than catching it
in real-time.

## Configuration

```yaml
# config/shadow-agents.example.yaml
shadow_agents:
  - name: security-shadow
    model: haiku
    mode: review
    watch:
      - agent: "*"
        triggers:
          - security_risk
          - code_written
    cost_control:
      max_reviews_per_day: 50
      skip_if_task_cost_below: 0.01

  - name: quality-shadow
    model: haiku
    mode: passive
    watch:
      - agent: content-agent
        triggers:
          - task_complete
      - agent: researcher-agent
        triggers:
          - task_complete
    cost_control:
      max_reviews_per_day: 30
      skip_if_task_cost_below: 0.05
```

### Configuration Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Shadow agent identifier |
| `model` | Yes | LLM model to use (prefer cheap models) |
| `mode` | Yes | One of: `passive`, `review`, `active` |
| `watch` | Yes | List of agent/trigger pairs to monitor |
| `cost_control` | No | Budget limits for shadow evaluation |

## Trigger Types

| Trigger | Description |
|---------|-------------|
| `code_written` | Agent produced or modified code |
| `security_risk` | Action involves credentials, external APIs, or privileged operations |
| `task_complete` | Agent finished a task (any task) |
| `error` | Agent encountered an error during execution |
| `all` | Fire on every action (expensive, use sparingly) |

### Trigger Selection Guide

- Start with `task_complete` in passive mode to understand baseline behavior.
- Add `security_risk` and `code_written` when you want proactive security monitoring.
- Use `error` to get a second opinion on agent error handling.
- Avoid `all` in production -- it generates high token cost with diminishing returns.

## Cost Control

Shadow agents are designed to run on the cheapest available model. Every shadow
evaluation costs tokens, so cost controls are built in:

1. **Max reviews per day:** Hard cap on total evaluations. Once reached, the shadow
   agent stops reviewing until the next day.
2. **Skip low-cost tasks:** Tasks below a cost threshold are not reviewed. If the
   original task cost $0.005, spending $0.002 to shadow-review it is wasteful.
3. **Cheap model mandate:** Shadow agents must use the cheapest available model.
   Shadow evaluation does not require frontier reasoning.
4. **Batch when possible:** Multiple small outputs from the same agent can be
   batched into a single shadow review.

## Evaluation Criteria

The shadow agent evaluates based on a standard checklist:

```
1. Does the output address the original task?
2. Are there factual claims that contradict known information?
3. Are there security concerns (exposed credentials, unsafe operations)?
4. Is the output complete or does it appear truncated?
5. Does the output quality match the agent's historical baseline?
```

Additional domain-specific criteria can be added per shadow agent in the config.

## Output Format

Shadow observations are logged in a structured format:

```json
{
  "shadow": "security-shadow",
  "watched_agent": "researcher-agent",
  "trigger": "task_complete",
  "mode": "review",
  "findings": [
    {
      "severity": "warning",
      "category": "security",
      "description": "Output contains an API URL with what appears to be an embedded token"
    }
  ],
  "recommendation": "Redact the token before storing or forwarding this output",
  "timestamp": "2026-02-28T14:30:00Z"
}
```

## Integration

- **Trajectory Pool:** Shadow findings are attached to the task trajectory as metadata.
  Recurring findings for the same agent/task type may trigger a reflexion cycle.
- **Circuit Breaker:** If a shadow agent in active mode rejects 3 consecutive outputs
  from the same agent, it can recommend opening a circuit breaker.
- **Metrics:** Shadow review counts and finding rates are tracked in the metrics database
  for weekly evolution reports.
- **Briefing:** Daily briefing includes a summary of shadow agent findings from the
  previous period.

## Implementation

The shadow agent system is implemented in `scripts/shadow-agent.sh`. It reads
configuration from `config/shadow-agents.yaml` and stores reviews in
`memory/shadow-reviews/`.

### Commands

```bash
# Run a single review for a specific agent and trigger
scripts/shadow-agent.sh review --target writer-agent --trigger code_written

# Pipe context from stdin
echo "task output here" | scripts/shadow-agent.sh review --target writer-agent --trigger code_written

# Show all shadow configurations and today's review counts
scripts/shadow-agent.sh status

# Batch review recent trajectory entries (last 24 hours, max 5)
scripts/shadow-agent.sh batch
```

### Review Output

Reviews are saved as markdown files in `memory/shadow-reviews/` with the naming
convention `YYYY-MM-DD-<target>-<trigger>-HHMMSS.md`. Each file includes:

- Observer and target metadata in an HTML comment
- Date, trigger, and mode information
- Quality assessment (APPROVE / SUGGEST / FLAG)
- Specific observations (1-3 bullet points)
- Actionable recommendation

### Built-in Safeguards

- **Daily limit:** Configurable per observer-target pair via `max_reviews_per_day`.
- **Cooldown:** Default 2-hour cooldown between reviews for the same target+trigger
  combination.
- **Cost control:** Uses `--quick` bridge preset (haiku model) for all reviews.
- **Graceful degradation:** Bridge failures do not propagate; the review is simply
  skipped.
