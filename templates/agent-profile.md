# Agent Profile Template

> Copy and customize this for each agent in your system.

## Agent: [agent-name]

**Role:** [One-line description]
**Primary Capability:** [e.g., web research, code analysis, content creation]
**Model:** [e.g., opus, sonnet, haiku]
**Schedule:** [e.g., on-demand, daily at 09:00, weekly]

## Capabilities

| Capability | Proficiency | Notes |
|-----------|------------|-------|
| [capability-1] | Primary | [context] |
| [capability-2] | Secondary | [context] |

## Operating Rules

1. [Rule specific to this agent]
2. [Rule specific to this agent]
3. Always record results in trajectory pool
4. Write reflexion after failures

## Learned Rules

### Tactical (from recent failures)

_None yet — rules will be added as the agent learns from experience._

### Strategic (from success patterns)

_None yet — rules will emerge from weekly evolution cycles._

## Recent Reflections

_Injected automatically from `memory/reflections/[agent-name]/` — last 3 relevant reflections appear here at runtime._

## Maker-Checker Pairing

- **When this agent is Maker:** Checked by [reviewer-agent]
- **When this agent is Checker:** Reviews output from [producer-agent]

## Performance Baseline

| Metric | Target | Current |
|--------|--------|---------|
| Success rate | > 80% | _pending_ |
| Avg tokens | < 15K | _pending_ |
| Avg duration | < 60s | _pending_ |

---

*Update this profile as the agent evolves. Tactical rules are added automatically after failures. Strategic rules are added during weekly evolution cycles.*
