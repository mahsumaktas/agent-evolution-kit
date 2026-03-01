# Self-Evolution Playbook

> **Operational Guide**
>
> This document covers the complete operational procedures for the self-evolution system. Every process is concrete, action-oriented, and paired with a rollback plan.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Daily Loop (After Every Task)](#2-daily-loop-after-every-task)
3. [Weekly Cycle (Sunday 23:00)](#3-weekly-cycle-sunday-2300)
4. [Prompt Evolution (SCOPE Pattern)](#4-prompt-evolution-scope-pattern)
5. [Cross-Agent Critique (MAR Pattern)](#5-cross-agent-critique-mar-pattern)
6. [Trajectory Pool Management](#6-trajectory-pool-management)
7. [Evolution Log](#7-evolution-log)
8. [Future Phases](#8-future-phases)
9. [Security and Constraints](#9-security-and-constraints)
10. [Appendix: Quick Reference Cards](#appendix-quick-reference-cards)

---

## 1. Overview

The orchestrator coordinates 7 sub-agents:

| Agent              | Role             | Focus                                         |
|--------------------|------------------|-----------------------------------------------|
| **social-media**   | Social media     | Post/thread generation, platform strategy     |
| **finance**        | Finance          | Market analysis, portfolio monitoring         |
| **monitor**        | System monitor   | Cron monitoring, health checks, metric collection |
| **researcher**     | Research         | Information gathering, source scanning, discovery |
| **security**       | Security         | Risk assessment, security review              |
| **analyst**        | Analysis         | Data analysis, reporting, pattern recognition |
| **content**        | Content          | Long-form content generation, documentation   |

### What Is Self-Evolution?

The process by which the orchestrator and its agents improve over time. Human intervention decreases, decision quality increases, and recurring errors diminish.

### 4-Layer Evolution Model

```
Layer 1: Reflexion (Immediate)
   Learning from every failed task, instant rule generation
       |
Layer 2: Prompt Evolution (Daily/Weekly)
   Tactical + strategic rules embedded into agent prompts
       |
Layer 3: Trajectory Learning (Weekly)
   Pattern extraction from successful/failed task history
       |
Layer 4: Routing Optimization (Future)
   ML-based model and agent routing
```

### Core Philosophy

- **Stability-first:** Do not touch a working system.
- **Small steps:** One change at a time.
- **Rollback always possible:** Changes that cannot be reversed are FORBIDDEN.
- **Measurement over intuition:** Proposing changes without metrics is FORBIDDEN.

---

## 2. Daily Loop (After Every Task)

The following flow runs automatically when any agent completes a task:

### Flow Diagram

```
Task completed
    |
    v
[Record to trajectory pool]
    |
    v
[Successful?]--NO-->[Generate reflexion]-->[Save to memory/reflections/<agent>/<date>.md]
    |                                         |
   YES                                        v
    |                              [Orthogonal strategy needed?]
    v                                    |YES-> [Run revision operator]
[Extract procedure summary]              |NO -> [Next task]
    |
    v
[Heuristic filter (Layer 1)]
    |
    +--> Score < 0.3 --> [Reject: send to archive]
    |
    +--> Score 0.3-0.7 --> [LLM evaluation (Layer 2)]
    |                          |
    |                          +--> Accept --> [Mark as rule candidate]
    |                          +--> Reject --> [Archive]
    |
    +--> Score > 0.7 --> [Accept: create tactical rule]
```

### Step-by-Step Process

**Step 1: Trajectory Record**
- When a task completes, the agent appends a record to `memory/trajectory-pool.json`.
- Required fields: agent, task_type, strategy, result, tokens_used, duration_s.

**Step 2: Success/Failure Branching**
- `result: "SUCCESS"` --> Extract a procedure summary (optional, only for complex tasks).
- `result: "FAILED"` or `"PARTIAL"` --> Generate a reflexion.

**Step 3: Reflexion Generation (On Failure)**
- File: `memory/reflections/<agent-name>/<YYYY-MM-DD>.md`
- Content: What happened, why it failed, what to do differently next time.
- If an orthogonal strategy is needed (a fundamentally different approach) --> the revision operator is triggered.

**Step 4: Heuristic Filter (Layer 1)**
- Automatic scoring based on token efficiency, task duration, and result quality.
- Score >= 0.7: Direct accept, becomes a tactical rule candidate.
- Score 0.3-0.7: Routed to LLM evaluation (Layer 2).
- Score < 0.3: Rejected, sent to archive.

**Step 5: Cross-Agent Critique (If Applicable)**
- Triggered only for "important" outputs (see Section 5).
- Routine tasks are exempt.

---

## 3. Weekly Cycle (Sunday 23:00)

Every Sunday at 23:00, the orchestrator runs the self-evolution cycle. This is a 5-phase process.

### 3.1 MEASURE

Statistics are extracted from `memory/trajectory-pool.json` for the current week:

| Metric            | Description                            | Source                |
|-------------------|----------------------------------------|-----------------------|
| Success rate      | Per-agent SUCCESS / total              | trajectory-pool.json  |
| Token consumption | Per-agent average tokens_used          | trajectory-pool.json  |
| Error types       | Grouped failure_reason distribution    | trajectory-pool.json  |
| Reflexion count   | Per-agent reflexions generated         | memory/reflections/   |
| Average duration  | Per-agent duration_s average           | trajectory-pool.json  |

**Delta analysis:** Comparison against the same fields from the previous week. Percentage changes are computed.

Example output:
```
=== WEEKLY MEASUREMENT: 2026-W09 ===

Agent          Success%  Delta   Avg Token  Delta   Reflexions
-------------- --------  ------  ---------  ------  ----------
researcher     85%       +5%     12.4K      -2.1K   2
social-media   92%       +3%     8.2K       -0.5K   1
finance        78%       -4%     15.1K      +1.2K   3
content        90%       0%      18.7K      -3.0K   1
analyst        88%       +2%     14.0K      -1.8K   1
security       95%       +1%     6.3K       -0.2K   0
monitor        97%       0%      4.1K       +0.1K   0

Top 3 errors: API rate limit (4), hallucination (2), missing source (2)
```

### 3.2 DIAGNOSE

Failure patterns are grouped into 4 categories:

| Category            | Example                                            | Typical Resolution                            |
|---------------------|----------------------------------------------------|-----------------------------------------------|
| **Model error**     | Hallucination, wrong format, instruction-following failure | Prompt update, model change                |
| **Tool error**      | API down, rate limit, timeout                      | Retry strategy, fallback, schedule change     |
| **Strategy error**  | Wrong approach, unnecessary steps, missing steps   | Strategic rule, approach change                |
| **Data error**      | Missing information, stale data, wrong source      | Source update, memory cleanup                  |

**Procedure:**
1. List all FAILED/PARTIAL records for the current week.
2. Assign each to one of the 4 categories.
3. Identify common patterns across reflexions.
4. Rank the top 3 most recurring errors.

### 3.3 PRESCRIBE

**RULE: Propose a SINGLE change. Bundled changes are FORBIDDEN.**

Change types (in priority order):

| Type              | When                               | Example                                  |
|-------------------|------------------------------------|------------------------------------------|
| Prompt update     | Model/strategy error               | Add "use thread format" rule             |
| Schedule change   | Tool error (rate limit)            | Move cron to 03:00                       |
| Strategy change   | Recurring strategy error           | Change research prioritization approach  |
| Model change      | Persistent model error             | Switch from mid-tier to frontier model   |

**Every proposal MUST include:**
- Expected impact (concrete, measurable)
- Rollback plan (how to reverse the change)
- Blast radius (what breaks in the worst case)

Example proposal:
```
PROPOSAL: Add tactical rule to social-media agent prompt
RULE: "IF post exceeds platform character limit, convert to thread format"
EXPECTED IMPACT: Thread post engagement increase of 20-30%
ROLLBACK: Remove the rule line from the social-media agent prompt
BLAST RADIUS: Only social-media post generation is affected
```

### 3.4 APPLY

1. The proposal is written to `memory/evolution-log.md` as DRAFT status.
2. The proposal is presented to the operator (via notification channel or terminal).
3. If the operator approves:
   - The change is implemented.
   - The evolution log is updated (DRAFT --> APPLIED).
4. If the operator rejects:
   - The rejection reason is recorded in the evolution log.
   - The proposal is deferred to the next cycle or cancelled.

**IMPORTANT:** No change reaches production without operator approval.

### 3.5 VERIFY (Following Week)

For the previous week's applied change:

```
[Measure the same metrics]
        |
        v
  [Improved?]
    |         |
   YES       NO
    |         |
    v         v
 [Keep]    [Rollback]
              |
              v
       [New diagnosis]
```

- Improvement: The change is permanently retained, evolution log updated to SUCCESSFUL.
- Degradation: The change is rolled back, evolution log updated to FAILED with reason, new DIAGNOSE begins.
- No change observed: Wait one more week, then decide.

---

## 4. Prompt Evolution (SCOPE Pattern)

Agent prompts contain 2 types of learned rules: tactical (immediate) and strategic (long-term).

### 4.1 Tactical Rules

**When created:** Immediately upon encountering an error or unexpected situation.

**Format:**
```
IF [condition] THEN [action]
```

**Examples:**
- `IF the vulnerability API returns 429, wait 30 minutes and retry at 03:00`
- `IF post exceeds character limit, convert to thread format`
- `IF API rate limit is approaching (remaining < 100), defer operations by 10 minutes`
- `IF source is older than 2 years, add a reliability warning`

**Constraints:**
- Maximum 10 tactical rules per agent.
- When capacity is exceeded, the oldest rule is pruned (FIFO).
- Rule creation is recorded in the trajectory pool.

**Expiry:** Tactical rules that have not been triggered for 4 weeks become removal candidates during the weekly review.

### 4.2 Strategic Rules

**When created:** Derived from success patterns during the weekly cycle.

**Format:**
```
For [topic], [approach] is more effective because [reason]
```

**Examples:**
- `For technical research, cross-referencing GitHub Issues + forums is more effective because single-source answers carry bias`
- `For financial analysis, 3-source cross-check is more effective because single-source analysis creates confirmation bias`
- `For thread posts, 4-6 items is optimal because fewer than 3 is superficial and more than 7 drops engagement`

**Constraints:**
- Maximum 5 strategic rules per agent.
- Freshness check: A rule not triggered for 1 month becomes a removal candidate.
- Reviewed during the weekly cycle; quarterly deep review.

### 4.3 Rule Placement

Each agent's system prompt contains the following sections:

```markdown
## Learned Rules

### Tactical Rules
- IF [condition1] THEN [action1]
- IF [condition2] THEN [action2]

### Strategic Principles
- For [topic1], [approach1] is more effective because [reason1]
- For [topic2], [approach2] is more effective because [reason2]
```

**Important:**
- Rules are plain text, not JSON.
- Each rule occupies a single line.
- Rules added to prompts NEVER contain API keys, secrets, or credentials.

---

## 5. Cross-Agent Critique (MAR Pattern)

For important outputs, agents evaluate each other. Routine tasks are exempt.

### 5.1 Critique Matrix

| Producer Agent  | Reviewer Agent  | Review Focus                                    |
|-----------------|-----------------|-------------------------------------------------|
| researcher      | analyst         | Research depth, source diversity                |
| social-media    | content         | Tone, engagement potential, factual accuracy    |
| finance         | security        | Risk assessment, assumption validation          |
| content         | social-media    | Platform suitability, viral potential           |
| analyst         | researcher      | Completeness, missing area identification       |
| monitor         | security        | System measurement accuracy                     |

### 5.2 Critique Flow

```
[Producer agent generates output]
        |
        v
[Important output?]--NO-->[Use directly]
        |
       YES
        |
        v
[Send to reviewer agent]
        |
        v
[2-3 sentence evaluation]
        |
        v
[Serious issue found?]--NO-->[Accept, use as-is]
        |
       YES
        |
        v
[Return feedback to producer agent]
        |
        v
[Regenerate output]
        |
        v
[Record to trajectory pool (with critique result)]
```

### 5.3 "Important" Output Criteria

An output is considered "important" if at least one of the following applies:
- It will be published externally (post, report, email).
- It contains a financial decision.
- It will change system configuration.
- It is the first time this task type has been performed.

### 5.4 Critique Rules

- The reviewer agent writes MAX 2-3 sentences (lengthy analysis is FORBIDDEN).
- A serious issue is defined as: factual error, security risk, or tone mismatch.
- Minor improvements do not trigger critique (left to the producer agent's discretion).
- Critique results are recorded in the trajectory pool (`critique_by`, `critique_result` fields).

---

## 6. Trajectory Pool Management

### 6.1 File Locations

```
memory/trajectory-pool.json             # Active records (max 100)
memory/trajectory-archive/YYYY-MM.json  # Archive (monthly)
```

### 6.2 Record Format

```json
{
  "id": "2026-02-28-researcher-research-vuln-scan",
  "agent": "researcher",
  "task_type": "research",
  "strategy": "Scan the last 7 days of vulnerability disclosures via API",
  "result": "SUCCESS",
  "failure_reason": null,
  "tokens_used": 12400,
  "duration_s": 45,
  "key_actions": [
    "Vulnerability API query (7 days)",
    "128 entries filtered",
    "3 critical entries reported"
  ],
  "lessons": "API pagination with 2000-item limit yields best performance",
  "critique_by": null,
  "critique_result": null,
  "created_at": "2026-02-28T14:30:00Z"
}
```

**Required fields:**

| Field          | Type        | Description                                     |
|----------------|-------------|-------------------------------------------------|
| id             | string      | Unique: `date-agent-task`                       |
| agent          | enum        | researcher / social-media / finance / content / analyst / security / monitor |
| task_type      | enum        | research / post / analysis / report / scan / monitor |
| strategy       | string      | Approach used (1-2 sentences)                   |
| result         | enum        | SUCCESS / FAILED / PARTIAL                      |
| failure_reason | string/null | Failure reason (null if successful)             |
| tokens_used    | number      | Total token consumption                         |
| duration_s     | number      | Task duration (seconds)                         |
| key_actions    | string[]    | List of main actions taken                      |
| lessons        | string/null | Learning note (1 sentence, optional)            |

**Optional fields:**

| Field           | Type        | Description                    |
|-----------------|-------------|--------------------------------|
| critique_by     | string/null | Agent that performed critique  |
| critique_result | string/null | Critique summary               |
| created_at      | ISO 8601    | Record timestamp               |

### 6.3 Size Management

| Rule                       | Value    | Description                                    |
|----------------------------|----------|------------------------------------------------|
| Max active records         | 100      | Oldest successful record moves to archive      |
| Successful record retention| 4 weeks  | Then moved to archive                          |
| Failed record retention    | 8 weeks  | Kept longer for pattern analysis               |
| Archive format             | Monthly JSON | `memory/trajectory-archive/2026-02.json`    |

**Weekly cleanup procedure (Sunday 22:50, before self-evolution cycle):**
1. Identify SUCCESS records older than 4 weeks.
2. Identify FAILED/PARTIAL records older than 8 weeks.
3. Move identified records to the corresponding monthly archive file.
4. Update trajectory-pool.json.

### 6.4 Usage Scenarios

**When a similar task arrives:**
- The last 3 successful trajectories are provided as in-context examples to the agent.
- The agent references previous successful strategies.
- Failed trajectories are also provided (to avoid repeating the same mistakes).

**Weekly MEASURE:**
- Statistics are extracted from all active records.
- Per-agent success rate, token consumption, and duration are computed.

**Prompt evolution:**
- Rules are derived from recurring success/failure patterns.
- Creating rules without trajectory data is FORBIDDEN.

---

## 7. Evolution Log

### File Location

```
memory/evolution-log.md
```

### Record Format

Each change is recorded in the following format:

```markdown
## 2026-W09 (March 3-9)

- **Change:** Added "use thread format for posts" strategic rule to social-media agent prompt
- **Reason:** Over the last 2 weeks, threaded posts generated 40% higher engagement
- **Expected impact:** Engagement rate increase
- **Rollback:** Remove the rule line from the social-media agent prompt
- **Status:** APPLIED
- **Result:** _(filled during the following week's VERIFY)_
```

### Status Values

| Status     | Meaning                                       |
|------------|-----------------------------------------------|
| DRAFT      | Proposal ready, awaiting operator approval    |
| APPLIED    | Approved, change implemented                  |
| SUCCESSFUL | VERIFY result positive, change retained       |
| FAILED     | VERIFY result negative, rolled back           |
| REJECTED   | Operator did not approve                      |
| DEFERRED   | Postponed to the next cycle                   |

### Example Chronology

```markdown
## 2026-W08 (February 24 - March 2)

- **Change:** Added "IF vulnerability API returns 429, wait 30 min" tactical rule to researcher prompt
- **Reason:** 3 consecutive tasks hit the API rate limit
- **Expected impact:** Rate-limit failures should drop to 0%
- **Rollback:** Remove the rule line from the researcher agent prompt
- **Status:** SUCCESSFUL
- **Result:** W09 had 0 rate limit errors. Rule retained.

## 2026-W09 (March 3-9)

- **Change:** Switched finance agent model from mid-tier to frontier
- **Reason:** 3 hallucinations in financial analysis (weekly)
- **Expected impact:** Hallucination reduction of 50%
- **Rollback:** Revert model to mid-tier
- **Status:** APPLIED
- **Result:** _(awaiting W10 VERIFY)_
```

---

## 8. Future Phases

### Phase 3: ML-Based Routing (RouteLLM + Cognify)

**Goal:** Replace rule-based `[Quality, Cost, Speed]` routing with data-driven routing.

**Approach:**
- RouteLLM for automatic model selection based on task type.
- Cognify for Pareto-optimal quality/cost/latency configurations.
- Predict the most suitable model/agent combination for each task.

**Prerequisites:**
- Sufficient trajectory pool data (minimum 500 records).
- At least 3 months of successful Phase 2 operation.
- Sufficient A/B test data across different model combinations.

**Expected benefits:**
- 20-30% reduction in token cost.
- Cheaper model usage while preserving quality.
- Latency optimization (fast model for simple tasks).

### Phase 4: Deep Evolution (TextGrad + Tool Generator)

**Goal:** Gradient-based prompt improvement and runtime tool synthesis.

**Approach:**
- TextGrad for automatic prompt optimization.
- Agents synthesize needed tools at runtime.
- Continuous optimization loop.

**Prerequisites:**
- Phase 3 must be stable for at least 2 months.
- Sufficient compute budget (TextGrad is compute-intensive).
- Security sandbox must be ready.

**Risks:**
- Prompt drift (prompt becoming incoherent over time).
- Security risks from tool synthesis.
- Phase 4 carries the highest risk but also the highest potential return.

---

## 9. Security and Constraints

### Invariant Rules (Red Lines)

| Rule                                                                | Rationale                                         |
|---------------------------------------------------------------------|---------------------------------------------------|
| Evolution NEVER reaches production without operator approval        | Human-in-the-loop is mandatory                    |
| Every change MUST have a rollback plan                              | Irreversible change = unacceptable risk           |
| Bundled changes are FORBIDDEN -- MAX 1 change per cycle             | Isolation is required to identify what broke      |
| Rules added to agent prompts NEVER contain API keys or secrets      | Secret leak prevention                            |
| Trajectory pool records NEVER contain sensitive data (passwords, tokens) | Data leak prevention                         |
| Self-modifying code is FORBIDDEN -- only prompt/config changes      | Prevents uncontrollable mutation                  |

### Evolution Scope Limits

**Mutable (via evolution):**
- Agent system prompts (add/remove tactical and strategic rules)
- Agent model configuration (model changes)
- Cron schedules (timing changes)
- Agent strategy parameters

**Immutable (via evolution):**
- Orchestrator core logic
- Agent code structure
- MCP server configuration
- Security constraints
- File system access permissions

### Data Security

- In trajectory records: task summary YES, raw data NO.
- In reflexions: error analysis YES, user data NO.
- In the evolution log: change details YES, API endpoints NO.
- In critique results: evaluation YES, source content NO.

### Escalation Matrix

| Situation                      | Action                                      |
|--------------------------------|---------------------------------------------|
| Tactical rule creation         | Automatic (orchestrator initiative)         |
| Strategic rule creation        | Presented during the weekly cycle           |
| Model change                   | Operator approval REQUIRED                  |
| Agent addition/removal         | Operator approval REQUIRED                  |
| Security constraint changes    | FORBIDDEN (operator must apply manually)    |

---

## Appendix: Quick Reference Cards

### Weekly Cycle Checklist

```
[ ] 22:50 - Trajectory pool cleanup
[ ] 23:00 - MEASURE: Extract statistics
[ ] 23:05 - DIAGNOSE: Group failure patterns
[ ] 23:10 - PRESCRIBE: Propose SINGLE change
[ ] 23:15 - VERIFY previous week's change
[ ] 23:20 - Update evolution log
[ ] 23:25 - Present proposal to operator
```

### File Map

```
memory/
  trajectory-pool.json           # Active task records (max 100)
  trajectory-archive/
    YYYY-MM.json                 # Monthly archive
  reflections/
    researcher/                  # Per-agent reflexions
    social-media/
    finance/
    content/
    analyst/
    security/
    monitor/
  evolution-log.md               # Full change history
```

### Decision Tree: Should I Make This Change?

```
Does this solve a REAL, OBSERVED problem?
    |NO  -> DO NOT PROCEED
    |YES
    v
Can I test it in isolation?
    |NO  -> DO NOT PROCEED, flag it
    |YES
    v
Can it be rolled back if it breaks?
    |NO  -> DO NOT PROCEED
    |YES
    v
Will harm occur if I do nothing?
    |NO  -> DO NOT PROCEED (unnecessary change)
    |YES
    v
Is the blast radius acceptable?
    |NO  -> DO NOT PROCEED, find alternative
    |YES
    v
PROCEED -> single change, with rollback plan, recorded in evolution log
```

---

## References

- Shinn et al. (2023). *Reflexion: Language Agents with Verbal Reinforcement Learning.* arXiv:2303.11366.
- Li et al. (2025). *SCOPE: Optimizing Key Design Choices for LLM Agents.* arXiv:2512.15374.
- Du et al. (2025). *MARS: Multi-Agent Reasoning System.* arXiv:2601.11974.
- Chen et al. (2025). *MAR: Multi-Agent Review.* arXiv:2512.20845.
- Ye et al. (2025). *SE-Agent: Self-Evolving Agents.* arXiv:2508.02085.
