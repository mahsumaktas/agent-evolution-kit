# Prompt Evolution

Dual-stream prompt optimization system based on the SCOPE framework (arXiv 2512.15374). Agent prompts evolve through two independent streams: tactical rules for immediate error correction and strategic principles for long-term behavioral improvement.

## Overview

Static prompts degrade over time as environments change. Prompt Evolution keeps agent instructions current by continuously injecting learned rules derived from operational experience. Each agent maintains its own set of tactical and strategic rules, managed by the orchestrator during evolution cycles.

## Tactical Stream (Immediate Fixes)

Tactical rules are reactive patches triggered by specific failures. They address concrete, observed problems with concrete, actionable solutions.

**Format:** `IF [condition] THEN [action]`

**Examples:**
- `IF API returns 429, wait 30 minutes and retry at 03:00`
- `IF tweet exceeds 280 characters, convert to thread format`
- `IF search engine returns zero results, switch to alternate provider`
- `IF response takes longer than 60 seconds, abort and use cached data`
- `IF output contains non-UTF-8 characters, re-encode before publishing`

**Constraints:**
- Maximum 10 tactical rules per agent
- When limit is exceeded, oldest rule is removed (FIFO)
- Each rule has a 4-week expiry from creation date
- Expired rules are removed during the next evolution cycle

**Lifecycle:**
1. Agent fails a task
2. Metacognitive reflection extracts a principle (see `metacognitive-reflection.md`)
3. Principle is formatted as an IF/THEN tactical rule
4. Rule is injected into the agent's prompt
5. Rule expires after 4 weeks unless promoted

**Promotion to Strategic:**
Tactical rules that persist for 4 or more weeks without expiring (because the failure keeps recurring or the rule proves broadly useful) are candidates for promotion to the strategic stream. During the weekly evolution cycle, the orchestrator reviews surviving tactical rules and promotes those that represent general patterns rather than one-off fixes.

## Strategic Stream (Long-Term Principles)

Strategic rules are proactive guidelines extracted from success patterns. They capture general wisdom about how an agent should operate.

**Format:** `For [topic/domain], [approach] is more effective because [reason]`

**Examples:**
- `For external API calls, daytime hours are more reliable because rate limits are stricter at night`
- `For content generation, thread format outperforms single posts because engagement rate is 2.3x higher`
- `For vulnerability scanning, cross-referencing multiple databases is essential because single-source accuracy is below 70%`
- `For financial data, primary sources outperform aggregators because aggregator latency introduces stale data`

**Constraints:**
- Maximum 5 strategic rules per agent
- Quarterly review by the orchestrator (every 12 weeks)
- No automatic expiry — strategic rules persist until explicitly replaced
- Replacement requires evidence that the rule is no longer valid

**Extraction:**
Strategic rules are extracted during the weekly evolution cycle. The orchestrator analyzes successful trajectories from the past week, identifies recurring success patterns, and generalizes them into strategic principles.

## Prompt Structure

Every agent prompt includes a `Learned Rules` section appended after the base instructions:

```markdown
## Learned Rules

### Tactical (from recent failures)
1. [2026-02-15] IF API returns 429, wait 30 minutes and retry at 03:00
2. [2026-02-18] IF search returns zero results, switch to alternate provider
3. [2026-02-20] IF output contains URLs, verify each URL is reachable before publishing

### Strategic (from success patterns)
1. [2026-01-10] For external API calls, daytime hours are more reliable because rate limits are stricter at night
2. [2026-01-24] For content generation, thread format outperforms single posts because engagement rate is 2.3x higher
```

## Rule Quality Requirements

Every rule — tactical or strategic — must be:

| Criterion | Correct | Wrong |
|-----------|---------|-------|
| Specific | Set API timeout to 30 seconds | Be more careful with APIs |
| Actionable | Switch to provider B when provider A fails | Try harder next time |
| Measurable | Wait 30 minutes before retry | Wait a while before retry |
| Scoped | Applies to research-agent API calls | Applies to everything |

Vague rules are rejected. If a reflection produces a vague insight, it is discarded rather than injected as a low-quality rule.

## Logging

All rule changes are logged in the evolution log (`memory/evolution-log.md`):

```
[2026-02-20] TACTICAL ADD researcher: "IF API returns 429, wait 30min and retry"
[2026-02-20] TACTICAL EXPIRE researcher: "IF search fails, use cache" (4-week expiry)
[2026-02-20] TACTICAL PROMOTE → STRATEGIC researcher: "For API calls, daytime is more reliable"
[2026-03-01] STRATEGIC REMOVE analyst: "For reports, PDF is preferred" (quarterly review, no longer valid)
```

## Integration Points

- **Input:** Metacognitive reflection (principle reflections feed tactical stream)
- **Input:** Weekly evolution cycle (success patterns feed strategic stream)
- **Output:** Agent prompts (rules injected into prompt text)
- **Output:** Evolution log (all changes recorded)
