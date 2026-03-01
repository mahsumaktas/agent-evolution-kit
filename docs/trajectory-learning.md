# Trajectory Learning

Three evolution operators for improving agent performance over time, based on the SE-Agent framework (arXiv 2508.02085). These operators transform failure into structured learning by enforcing orthogonal retries, cross-agent synthesis, and risk-aware guidance injection.

## Overview

When agents fail, the natural instinct is to retry with minor adjustments. This leads to diminishing returns. Trajectory learning enforces three distinct operators — Revision, Recombination, and Refinement — each addressing a different failure mode with a different strategy.

## Operator 1: Revision (Orthogonal Strategy)

When a task fails, the agent does not try harder with the same approach. It tries a fundamentally different approach.

**Core Principle:** The revision strategy must be orthogonal (at a right angle) to the original strategy. Never a variant, always a departure.

**Examples:**

| Original Strategy | Wrong Revision | Correct Revision |
|-------------------|----------------|------------------|
| Web scraping fails | Try different selectors | Use official API instead |
| Long-form content underperforms | Make it slightly shorter | Switch to thread format |
| Search engine returns noise | Refine search query | Use a different search engine entirely |
| API rate-limited | Retry after shorter wait | Use cached data or alternate provider |

**Constraints:**
- Maximum 2 revision attempts per task
- After 2 failed revisions, the task escalates (see Operator Selection Flow below)
- Each revision must document why it is orthogonal to the previous attempt
- The orchestrator validates orthogonality before approving a revision

**Process:**
1. Task fails with strategy A
2. Agent proposes revision strategy B
3. Orchestrator checks: is B orthogonal to A? (not just a parameter tweak)
4. If orthogonal: execute B. If not: reject and request a truly different approach
5. If B also fails: one more revision attempt (strategy C, orthogonal to both A and B)
6. If C fails: escalate

## Operator 2: Recombination (Cross-Synthesis)

When two or more agents work on the same topic or related aspects of a problem, the orchestrator combines their strongest findings into a unified output.

**Core Principle:** Only the orchestrator performs recombination. Individual agents do not see each other's outputs directly. The orchestrator has the cross-agent view required for synthesis.

**Process:**
1. Multiple agents produce outputs on the same or overlapping topics
2. Orchestrator identifies overlapping areas and complementary strengths
3. Orchestrator synthesizes a combined output, taking the best elements from each
4. Attribution: source agents are credited in the combined output

**Example:**
```
researcher-agent produces: "CVE-2026-1234 affects nginx 1.25, severity HIGH"
analyst-agent produces: "Our infrastructure runs nginx 1.25 on 3 servers"
security-agent produces: "Patch available in nginx 1.25.1, zero-downtime upgrade possible"

Orchestrator recombination:
"CVE-2026-1234 (HIGH) affects our nginx 1.25 deployment on 3 servers.
 Patch: upgrade to 1.25.1 (zero-downtime). Priority: immediate.
 Sources: researcher (CVE detail), analyst (impact), security (remediation)"
```

**When to Use:**
- Two agents independently produce partial answers to the same question
- One agent's output can enhance or validate another agent's output
- A comprehensive view requires combining domain-specific perspectives

## Operator 3: Refinement (Risk-Aware Guidance)

Refinement extracts common blind spots and recurring failure patterns from the trajectory pool and injects preventive guidance into agent prompts.

**Core Principle:** Learn from collective failure history, not just individual task failures. Patterns that appear across multiple tasks indicate systemic blind spots.

**Process:**
1. During the weekly evolution cycle, the orchestrator reviews all failure trajectories from the past week
2. Common failure patterns are identified (e.g., "3 out of 5 API tasks failed due to missing timeout")
3. Preventive guidance is formulated as "avoid these" rules
4. Rules are injected into relevant agent prompts

**Constraints:**
- Maximum 3 new refinement rules per week (prevents prompt bloat)
- Rules are formatted as specific warnings, not vague advice
- Each rule must reference the pattern it addresses

**Example Refinement Rules:**
- "API calls without timeout have failed 3 times this week. Always set a 30-second timeout."
- "Single-source research produced inaccurate results twice. Cross-reference with at least 2 sources."
- "Outputs over 2000 words were rejected by quality gate 4 times. Keep reports under 1500 words unless explicitly requested."

## Operator Selection Flow

```
Task failed
  |
  v
First failure for this task?
  |
  ├── YES --> Revision (try orthogonal strategy)
  |             |
  |             v
  |           Revision also failed?
  |             |
  |             ├── YES (attempt 1) --> Revision again (orthogonal to both prior)
  |             |                         |
  |             |                         v
  |             |                       Still failed?
  |             |                         |
  |             |                         ├── YES --> Escalation to orchestrator
  |             |                         └── NO  --> Record success trajectory
  |             |
  |             └── NO --> Record success trajectory
  |
  └── NO --> Is output from another agent available on this topic?
              |
              ├── YES --> Recombination (synthesize cross-agent outputs)
              └── NO  --> Escalation to orchestrator

Weekly evolution cycle:
  |
  v
Refinement (extract blind spots from past week's failures)
```

## Recording

Every operator application is recorded in the trajectory pool:
- **Revision:** original strategy, revision strategy, orthogonality justification, result
- **Recombination:** source agents, source outputs, synthesized output
- **Refinement:** failure pattern, generated rule, target agents

See `record-and-replay.md` for trajectory pool schema and management.

## Integration Points

- **Input:** Failed task results trigger Revision
- **Input:** Multi-agent overlapping outputs trigger Recombination
- **Input:** Weekly failure review triggers Refinement
- **Output:** Revised task attempts (Revision)
- **Output:** Synthesized outputs (Recombination)
- **Output:** Agent prompt updates (Refinement feeds into Prompt Evolution)
