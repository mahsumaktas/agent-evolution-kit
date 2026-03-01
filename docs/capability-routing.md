# Capability-Based Routing

Skill-based task routing with performance tracking. Routes tasks to the
best-suited agent based on capabilities, availability, historical performance,
and cost.

## Capability-Agent Matrix

| Capability | Primary | Secondary | Fallback |
|---|---|---|---|
| Web research | researcher-agent | analyst-agent | bridge |
| Code analysis | analyst-agent | security-agent | bridge |
| Content writing | content-agent | social-media-agent | orchestrator |
| Financial analysis | finance-agent | analyst-agent | researcher-agent |
| System health | security-agent | orchestrator | monitor-agent |
| Social media | social-media-agent | content-agent | researcher-agent |
| Security audit | security-agent | analyst-agent | orchestrator |
| Trend detection | researcher-agent | social-media-agent | analyst-agent |

### Matrix Rules

- **Primary**: First choice. Has the strongest capability match and typically
  the best success rate for this task type.
- **Secondary**: Used when primary is unavailable or has a low success rate.
  Competent but not specialized.
- **Fallback**: Last resort. Often uses a general-purpose bridge (external LLM
  call) or the orchestrator itself. Acceptable quality but not optimal.

## Routing Decision Factors

Evaluated in priority order:

1. **Capability match** (required) -- Can the agent perform this task type at
   all? If not, skip to the next candidate.
2. **Agent availability** -- Is the agent idle and ready to accept work?
   Busy agents are skipped.
3. **Historical success rate** -- What percentage of similar tasks has this
   agent completed successfully? Pulled from the trajectory pool.
4. **Cost** -- For equivalent capability, prefer the cheaper model. Simple
   tasks do not need expensive models.

## Routing Flow

```
Task arrives
  |
  v
Determine task type (from task metadata or content analysis)
  |
  v
Look up primary agent for this task type
  |
  v
Primary available?
  |
  +-- YES --> Success rate >= 70%?
  |             |
  |             +-- YES --> Route to primary
  |             |
  |             +-- NO --> Route to secondary
  |
  +-- NO --> Secondary available?
               |
               +-- YES --> Route to secondary
               |
               +-- NO --> Route to fallback (bridge or orchestrator)
```

## Success Rate Tracking

Success rates are calculated from the trajectory pool:

```json
{
  "agent": "researcher-agent",
  "capability": "web_research",
  "total_tasks": 47,
  "successful": 42,
  "failed": 5,
  "success_rate": 0.89,
  "avg_duration_seconds": 12.3,
  "last_updated": "2026-01-15T10:00:00Z"
}
```

### Calculation Rules

- **Window**: Rolling 30-day window. Older data is discounted but not deleted.
- **New task type**: If an agent has no history for a task type, route to the
  primary agent (no data = trust the matrix). Success rate defaults to 0.5
  until 10+ data points are collected.
- **Minimum sample size**: Success rate is not used for routing decisions until
  at least 10 tasks of that type have been recorded.

## Failure Handling

- **3 consecutive same-type failures**: Temporarily disable the agent for that
  task type. Route to secondary until the agent demonstrates recovery
  (1 successful task of the same type re-enables it).
- **Circuit breaker integration**: If a tool the agent depends on has an OPEN
  circuit, the agent is considered unavailable for tasks requiring that tool
  (see [circuit-breaker.md](circuit-breaker.md)).
- **Fallback exhaustion**: If all three levels (primary, secondary, fallback)
  are unavailable, the task is queued with a `"blocked": true` flag and the
  operator is alerted.

## Dynamic Matrix Updates

The capability matrix is not static. It evolves based on observed performance:

1. **Weekly review**: During the weekly evolution cycle, agents with
   consistently high success rates (>90% over 4 weeks) in a non-primary
   capability may be promoted to secondary for that capability.
2. **Demotion**: Agents with success rates below 50% for 2 consecutive weeks
   in a primary capability are flagged for investigation.
3. **New capabilities**: When a new task type is identified, the orchestrator
   assigns a primary agent based on capability similarity and adds it to the
   matrix.

## Cost-Aware Routing

When multiple agents are equally capable and available:

| Task Complexity | Preferred Model Tier | Examples |
|---|---|---|
| Simple | Fast/cheap (e.g., Haiku) | Status checks, simple lookups |
| Medium | Balanced (e.g., Sonnet) | Analysis, content generation |
| Complex | Capable (e.g., Opus) | Multi-step reasoning, strategy |

Cost data is tracked in the metrics database alongside success rates.

## Integration with Other Patterns

- **Maker-Checker**: Routing determines which agent is the maker and which is
  the checker based on the capability matrix pairings
  (see [maker-checker.md](maker-checker.md)).
- **Reflexion**: When an agent fails a routed task, the reflexion protocol
  captures what went wrong. Insights may lead to matrix updates.
- **Autonomy Layers**: At Layer 3-4, routing is rule-based (this document).
  At Layer 5, routing could be ML-based with learned capability embeddings
  (see [autonomy-layers.md](autonomy-layers.md)).
