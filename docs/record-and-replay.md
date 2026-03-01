# Record and Replay

Two-level experience storage system based on the AgentRR framework (arXiv 2505.17716). Every significant task execution is recorded at two granularity levels — step-by-step procedures and high-level strategies — enabling future tasks to benefit from past experience through in-context example injection.

## Overview

Agents improve by remembering what worked. Record and Replay captures successful (and failed) task executions in a structured trajectory pool, then retrieves relevant past trajectories when similar tasks arrive. This provides agents with concrete examples of how to handle tasks they have seen before, without requiring prompt changes or retraining.

## Low-Level Recording (Step-by-Step)

Captures the full execution path of a task: every action taken, in order.

**Purpose:** Serve as in-context examples for similar future tasks. When an agent faces a task it has handled before, the low-level recording shows exactly what steps to follow.

**What is Recorded:**
- Ordered list of actions taken
- Input/output for each step
- Branching decisions (why path A was chosen over path B)
- Error recovery steps (if any intermediate step failed and was retried)

**Example — Vulnerability Scanning:**
```
1. Query NVD API with product="nginx" version="1.25"
2. Filter: severity >= HIGH → 12 results
3. Cross-reference with GitHub Advisory Database → 9 confirmed
4. Rank by CVSS score descending
5. Check patch availability for top 5
6. Generate report: 5 actionable CVEs with remediation steps
```

**Example — Content Research:**
```
1. Query trending topics API for last 7 days
2. Filter by category: technology → 34 topics
3. Score by engagement velocity (likes + shares per hour)
4. Select top 5 by velocity
5. For each: pull 3 sample posts with highest engagement
6. Summarize patterns: format, length, tone, timing
```

## High-Level Recording (Strategy Summary)

Captures the general approach that worked, abstracted away from specific steps.

**Purpose:** Guide strategy selection for new tasks. When an agent faces a novel task within a known domain, the high-level summary suggests which approach to take without prescribing exact steps.

**Examples:**
- "For vulnerability scanning, cross-referencing NVD with GitHub Advisory gives the most reliable results. Single-source scanning misses approximately 25% of confirmed vulnerabilities."
- "For content research, engagement velocity (not total engagement) is the best predictor of trending potential. Topics with high velocity in the last 48 hours outperform those with high total engagement over 7 days."
- "For financial analysis, primary data sources (SEC filings, central bank reports) outperform aggregator sites. Aggregator latency introduces 4-8 hours of stale data."

## Trajectory Pool

All recordings are stored in a single trajectory pool.

**Location:** `memory/trajectory-pool.json`

**Record Schema:**
```json
{
  "id": "2026-02-28-researcher-cve-scan",
  "agent": "researcher",
  "task_type": "research",
  "strategy": "API query + cross-reference approach",
  "result": "SUCCESS",
  "failure_reason": null,
  "tokens_used": 12500,
  "duration_s": 45,
  "key_actions": [
    "NVD API query",
    "GitHub Advisory cross-reference",
    "CVSS ranking",
    "Patch availability check"
  ],
  "low_level_steps": [
    "Query NVD API with product and version",
    "Filter by severity >= HIGH",
    "Cross-reference with GitHub Advisory",
    "Rank by CVSS descending",
    "Check patch availability for top results",
    "Generate remediation report"
  ],
  "high_level_summary": "Cross-referencing NVD + GitHub Advisory gives most reliable vulnerability results",
  "lessons": "Daytime API calls have better rate limits than nighttime",
  "timestamp": "2026-02-28T14:30:00Z",
  "expiry": "2026-03-28T14:30:00Z"
}
```

**Required Fields:**
- `id`: Unique identifier (date-agent-task format)
- `agent`: Which agent executed the task
- `task_type`: Category for matching (research, analysis, content, security, monitoring)
- `result`: SUCCESS or FAILURE
- `timestamp`: ISO 8601 execution time

**Optional but Recommended:**
- `strategy`: One-line description of the approach
- `key_actions`: List of significant actions (for quick scanning)
- `low_level_steps`: Full step-by-step recording
- `high_level_summary`: Abstracted strategy summary
- `lessons`: Key takeaway (feeds into prompt evolution)
- `failure_reason`: Why it failed (required for FAILURE records)
- `tokens_used`: Token cost for cost tracking
- `duration_s`: Execution time in seconds

## Size Management

The trajectory pool has a hard maximum of 100 active records to prevent unbounded growth.

**Retention Rules:**
| Record Type | Retention Period |
|-------------|-----------------|
| Successful task | 4 weeks from creation |
| Failed task | 8 weeks from creation (failures are more valuable for learning) |
| Promoted to strategic | No expiry (moved to agent's strategic rules) |

**Overflow Handling:**
When the pool reaches 100 records and a new record needs to be added:
1. Remove expired records first
2. If still at capacity, remove the oldest SUCCESS record
3. Never remove FAILURE records before their 8-week retention

**Archiving:**
Monthly archive job moves expired records to `memory/trajectory-archive/YYYY-MM.json`. Archives are retained indefinitely for long-term pattern analysis but are not used for in-context injection.

## Replay: Using Past Trajectories

When a new task arrives, the orchestrator searches the trajectory pool for relevant past experience.

**Matching Process:**
1. Match by `task_type` (exact match)
2. Among matches, rank by relevance (keyword overlap between task description and trajectory)
3. Select top 3 most relevant trajectories

**Injection Format:**
Selected trajectories are injected into the agent's prompt as in-context examples, each limited to 500 tokens:

```
## Past Experience (similar tasks)

### Example 1: [strategy summary] (SUCCESS, 2026-02-28)
Steps taken: [low_level_steps abbreviated]
Lesson: [lessons field]

### Example 2: [strategy summary] (FAILURE, 2026-02-25)
What went wrong: [failure_reason]
Lesson: [lessons field]
```

**Rules:**
- Maximum 3 trajectories injected per task (more adds noise, not signal)
- Each trajectory summary must stay under 500 tokens
- Include at least one FAILURE trajectory if available (learning from mistakes is as valuable as learning from success)
- If no matching trajectories exist, skip injection (do not inject unrelated examples)

## Integration Points

- **Input:** Metacognitive reflection procedure reflections (low-level recordings)
- **Input:** Task completion events (high-level summaries)
- **Output:** In-context examples injected into agent prompts during task assignment
- **Output:** Monthly archives for long-term analysis
- **Related:** Trajectory learning operators use trajectory pool for Refinement analysis

## Implementation

Script: `scripts/replay.sh`
Storage: `memory/trajectory-pool.json`
Bridge flag: `--replay`
