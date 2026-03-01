# Architecture: Multi-Agent Orchestration System

> **References:** ToolOrchestra (2511.21689), AgentOrchestra (2506.12508), SE-Agent (2508.02085), Reflexion (2303.11366), SCOPE (2512.15374), MARS (2601.11974)
>
> This document defines the technical orchestration architecture for a self-evolving multi-agent system. It covers routing, delegation, learning loops, fault tolerance, and autonomous infrastructure.

---

## Table of Contents

1. [Preference-Aware Routing](#1-preference-aware-routing)
2. [Agent-as-Tool Delegation](#2-agent-as-tool-delegation)
3. [Self-Evolution](#3-self-evolution)
4. [Cross-Agent Consensus](#4-cross-agent-consensus)
5. [Reflexion Protocol](#5-reflexion-protocol)
6. [Trajectory Evolution](#6-trajectory-evolution)
7. [Prompt Evolution (SCOPE)](#7-prompt-evolution--scope-pattern)
8. [Record and Replay](#8-record--replay)
9. [Metacognitive Reflection (MARS)](#9-metacognitive-reflection--mars-pattern)
10. [Hybrid Evaluation](#10-heuristic--llm-hybrid-evaluation)
11. [Bridge](#11-bridge--full-power-llm-access)
12. [Tool Generator](#12-tool-generator--autonomous-tool-creation)
13. [Predictive Engine](#13-predictive-engine)
14. [Autonomous Research](#14-autonomous-research)
15. [System Management](#15-system-management)
16. [Reflexion v2](#16-reflexion-protocol-v2--vector-db-integration)
17. [Maker-Checker Loop](#17-maker-checker-loop)
18. [Circuit Breaker](#18-circuit-breaker)
19. [Capability-Based Routing](#19-capability-based-routing-matrix)
20. [Bi-Temporal Memory](#20-bi-temporal-memory)
21. [Self-Improvement Cycle](#21-self-improvement-cycle)
22. [Autonomous Infrastructure Scripts](#22-autonomous-infrastructure-scripts)
23. [Sandbox Pipeline](#23-sandbox-pipeline)
24. [Extension Development Lifecycle](#24-extension-development-lifecycle)
25. [Full Power Operation Matrix](#25-full-power-operation-matrix)
26. [Inter-Section Data Flow](#inter-section-data-flow)
27. [References](#references)

---

## 1. Preference-Aware Routing

Every incoming task is assigned a 3-dimensional decision vector: **[Quality, Cost, Speed]**.

| Task Type         | Quality | Cost | Speed    | Model Tier     |
|-------------------|---------|------|----------|----------------|
| Content creation  | high    | low  | medium   | Frontier       |
| Code review       | high    | low  | low      | Frontier       |
| Email triage      | low     | zero | high     | Fast/Free-tier |
| News summary      | medium  | zero | high     | Fast/Free-tier |
| Research analysis | high    | low  | medium   | Frontier       |
| Urgent alert      | medium  | low  | CRITICAL | Lowest-latency |
| Spam filter       | low     | zero | high     | Small/Free     |

**Routing Rules:**

- Every new task receives a `[Q, C, S]` profile at creation time.
- Tasks without an explicit profile default to `[medium, low, medium]`.
- `Speed=CRITICAL` selects the lowest-latency provider; cost is ignored.
- `Quality=high` routes to frontier models only (never fast/free-tier).
- `Cost=zero` restricts to free-tier providers only.
- **Fallback:** If the primary provider fails, route to the next provider matching the same profile.

---

## 2. Agent-as-Tool Delegation

Agents operate in two modes: **cron** (scheduled, autonomous) and **tool** (on-demand invocation by the orchestrator).

**Mechanism:** Spawn a sub-session, send a prompt, await the result.

### When to Use Each Mode

| Situation                            | Mode | Example                                        |
|--------------------------------------|------|------------------------------------------------|
| Scheduled, recurring work            | Cron | Daily posting, email triage, research cycles   |
| Decision required by orchestrator    | Tool | "Is this PR safe?", "Is this expense valid?"   |
| Ad-hoc need, context-dependent       | Tool | "Research this topic and report back in 2 min" |
| Routine monitoring                   | Cron | System health, rate limits, cron health        |

### Agent Tool Cards

| Agent               | Tool Capability                              | Typical Response |
|----------------------|----------------------------------------------|------------------|
| researcher-agent     | Research queries, CVE scanning, trend analysis | 30-60s          |
| social-media-agent   | Post analysis, engagement prediction          | 15-30s          |
| finance-agent        | Budget checks, spending analysis, scenarios   | 15-30s          |
| monitor-agent        | System health snapshot, resource checks       | 10-20s          |
| security-agent       | Security scans, rate limit status             | 10-20s          |

**Rule:** In tool mode, the result ALWAYS returns to the orchestrator. Agents never respond directly to the operator in tool mode.

### Orchestrator Role Limits (IRON RULE)

The orchestrator is a pure coordinator. The following matrix defines its execution boundaries:

| Operation                        | Permission | Mechanism                        |
|----------------------------------|------------|----------------------------------|
| File reading (cat, ls, grep)     | ALLOWED    | Direct execution                 |
| Running existing scripts         | ALLOWED    | Direct execution                 |
| System info (date, uptime)       | ALLOWED    | Direct execution                 |
| Git read operations              | ALLOWED    | Direct execution                 |
| File writing/creation            | FORBIDDEN  | Delegate to agent or bridge      |
| File editing                     | FORBIDDEN  | Delegate to agent or bridge      |
| Code writing                     | FORBIDDEN  | Delegate to agent or bridge      |
| Script creation                  | FORBIDDEN  | Delegate to agent or bridge      |

**Rationale:** Without this constraint, the orchestrator tends to bypass the entire agent pipeline and implement directly. This matrix structurally prevents that behavior.

---

## 3. Self-Evolution

A weekly evolution cycle -- the expanded form of the self-improvement loop.

**Schedule:** Weekly (e.g., Sunday evening)

```
1. MEASURE
   - Cron success rate (this week vs. last week)
   - Content engagement trend
   - Task completion rate
   - Escalation/error count
   - Reflexion data: this week's failure reflections (see Section 5)
   - Trajectory pool statistics: success/failure rates by task type (see Section 8)
   - Prompt evolution logs: tactical/strategic rule changes (see Section 7)

2. DIAGNOSE
   - Why did failing crons fail? (model? prompt? timing? data?)
   - Why did engagement drop? (topic? timing? tone?)
   - Are there recurring errors?
   - Extract patterns from reflections: same agent failing the same way?
   - Blind spot analysis from trajectory pool: which task types consistently fail?

3. PRESCRIBE
   - Propose ONE change (small-step principle)
   - State the expected impact
   - State the rollback plan
   - Which Trajectory Evolution operator applies? (Revision/Recombination/Refinement -- Section 6)
   - Is a Prompt Evolution update needed? (Section 7)

4. APPLY
   - Obtain operator approval (escalation rule)
   - Apply after approval

5. VERIFY (next week)
   - Measure the same metrics
   - Improved? --> Keep
   - Degraded? --> Revert + new diagnosis
```

**Rules:**
- Maximum ONE change per cycle. Bundled changes are forbidden.
- No change is applied without operator approval.
- Rollback must always be possible.

---

## 4. Cross-Agent Consensus

A 3-step verification protocol for research findings.

```
RETRIEVE:   researcher-agent / analyst-agent brings the finding
VERIFY:     Orchestrator cross-checks with independent sources (web search, vector DB, docs)
SYNTHESIZE: Verified information is presented to the operator
```

**Rules:**
- Unverified information is NEVER presented to the operator.
- A single source is insufficient -- at least 2 independent sources required.
- Conflicting information: present both sides + orchestrator assessment.
- "Could not verify" is an acceptable outcome -- fabrication is not.

**When to apply:**
- Technical decision-requiring research findings
- Financial data/projections
- Security claims (CVE, vulnerability)

**When NOT to apply (overhead unnecessary):**
- News summaries (informational, not decisional)
- Creative content (creative output, not verification)
- Reminders (action, not verification)
- System commands (deterministic, verification unnecessary)

**Lightweight alternative: Cross-Agent Critique (see Section 5)**

When the full consensus protocol is too heavy (e.g., for creative outputs), the cross-agent critique matrix from Section 5 can substitute. Instead of independent source verification, another agent's review suffices.

---

## 5. Reflexion Protocol

> Source: Reflexion (arxiv 2303.11366), MAR (arxiv 2512.20845)

Every agent MUST perform a verbal self-evaluation after a failed task.

**Reflection content (3 questions):**
1. What went wrong?
2. Why did it fail?
3. What should be done differently next time?

**Rules:**
- Failed task --> reflection is MANDATORY (3-5 sentences)
- Successful task --> procedure summary is OPTIONAL (1-2 sentences)
- Reflection file location: `$AEK_HOME/memory/reflections/<agent>/<date>.md`
- The last 3 reflections are injected into each agent's prompt (in-context learning)
- Prompt injection format:
  ```
  ## Recent Failure Reflections
  - [date]: [3-5 sentence reflection]
  - [date]: [3-5 sentence reflection]
  - [date]: [3-5 sentence reflection]
  ```

### Cross-Agent Critique Matrix (MAR Pattern)

Agent A's output is reviewed by Agent B. Goal: catch blind spots, biases, and quality issues.

| Producer Agent       | Reviewer Agent       | Review Focus                            |
|----------------------|----------------------|-----------------------------------------|
| researcher-agent     | analyst-agent        | Research quality, source reliability     |
| social-media-agent   | content-agent        | Tone/engagement fit, language quality    |
| finance-agent        | security-agent       | Risk assessment, financial consistency   |
| content-agent        | social-media-agent   | Social media suitability, viral potential|
| analyst-agent        | researcher-agent     | Completeness, missed research angles     |

**Critique process:**
1. Producer agent completes its output
2. Reviewer agent receives the output, writes 1-3 sentence critique
3. Serious issue (wrong information, major quality problem) --> output returns to producer for correction
4. Minor issue --> presented to operator with critique notes attached
5. No issue --> presented directly to operator

**Critique triggering:**
- Critique is NOT mandatory for every output (cost/time overhead)
- Orchestrator decides: if task importance is high OR the producer's last 3 reflections contain similar failures --> trigger critique
- Routine work (news summary, reminders) --> SKIP critique

---

## 6. Trajectory Evolution

> Source: SE-Agent (arxiv 2508.02085)

Three evolution operators adapted from SE-Agent's framework.

### 6.1 Revision (Orthogonal Strategy)

When a task fails, do NOT "try harder" -- try a **completely different angle**.

**Examples:**
- researcher-agent could not find information via web search --> instead of repeating web search, try GitHub code search or academic paper search
- social-media-agent post got low engagement --> instead of repeating the same format, try a completely different format (thread vs. single post, serious vs. humorous)
- finance-agent cost estimate was wrong --> instead of repeating with the same model, calculate with a different data source

**Rules:**
- First failure --> Revision is triggered
- Revision strategy must NEVER be a variant of the previous attempt -- it must be orthogonal
- If Revision also fails --> escalation (ask the operator)
- Maximum 2 revision attempts, then STOP

### 6.2 Recombination (Cross-Synthesis)

When two agents work on the same topic, combine their strongest findings.

**Examples:**
- researcher-agent found technical details + analyst-agent added strategic perspective --> orchestrator synthesizes both
- social-media-agent produced 3 drafts --> content-agent combines the best elements into a superior version
- finance-agent cost analysis + security-agent risk analysis --> orchestrator combines and decides

**Rules:**
- If 2+ agent outputs exist on the same topic --> Recombination candidate
- Orchestrator synthesizes, not the agents (orchestrator advantage: sees all outputs)
- Synthesis attributes results to source agents

### 6.3 Refinement (Risk-Aware Guidance)

Extract common blind spots and risk patterns from past failures. Inject "avoid these" guidance into agent prompts.

**Examples:**
- If researcher-agent hit rate limits 3 times in the last month --> add rule: "Check rate limits before API calls, avoid NVD API during off-hours"
- If social-media-agent's last 5 posts had 3 with low engagement --> add rule: "Avoid these tones at these times on this platform"

**Rules:**
- Refinement runs during the weekly evolution cycle (Section 3, DIAGNOSE step)
- Extracts patterns from the last 4 weeks of failures in the trajectory pool (Section 8)
- Extracted patterns are added to the "Learned Rules" section of agent prompts (Section 7)
- Maximum 3 new refinement rules per week (aggressive changes forbidden)

### Operator Selection Flow

```
Task failed
  +-- First failure?
       +-- YES --> Revision (try orthogonal approach)
       +-- NO  --> Other agent output on same topic?
            +-- YES --> Recombination (synthesize)
            +-- NO  --> Escalation (ask the operator)

Weekly review:
  +-- Refinement (extract patterns from all failures)
```

---

## 7. Prompt Evolution -- SCOPE Pattern

> Source: SCOPE (arxiv 2512.15374)

A dual-stream prompt improvement system.

### 7.1 Tactical Stream (Immediate Fixes)

Specific, urgent rules generated from recent failures.

**Examples:**
- "NVD API applies rate limiting between 02:00-06:00 --> use web search fallback during these hours"
- "If API returns 429 --> wait 60s, retry, on 2nd failure try alternative scraping"
- "For localized content searches, alternative search engines may yield better results"

**Trigger:** Automatically generated at the moment of failure.

### 7.2 Strategic Stream (Long-Term Principles)

General principles extracted from success patterns.

**Examples:**
- "Asking questions in posts increases engagement by ~40%"
- "Using two CVE databases in cross-reference reduces false positives by ~60%"
- "Morning posting windows yield highest engagement for the target audience"

**Trigger:** Extracted during the weekly evolution cycle (Section 3).

### 7.3 Prompt Structure

Every agent prompt MUST contain the following section:

```markdown
## Learned Rules

### Tactical (from recent failures)
1. [date] [rule]
2. [date] [rule]
...

### Strategic (from success patterns)
1. [date] [rule]
2. [date] [rule]
...
```

**Rules:**
- Maximum 10 tactical + 5 strategic rules per agent
- When the limit is exceeded, the oldest rule is removed (FIFO)
- Every rule must be specific and actionable
- Vague rules are FORBIDDEN: "be more careful" is WRONG. "Set API call timeout to 30s" is CORRECT.
- Tactical rules expire after 4 weeks (if the issue persists, promote to strategic)
- Strategic rules do not expire but are reviewed quarterly
- Rule additions/removals are logged in `$AEK_HOME/memory/prompt-evolution-log.md`

---

## 8. Record & Replay

> Source: AgentRR (arxiv 2505.17716)

A two-level experience storage system.

### 8.1 Low-Level (Step-by-Step Recording)

The complete execution path of successful tasks. Used as in-context examples when similar tasks arise in the future.

**Example:** researcher-agent CVE scan:
1. Pull last 24 hours of CVEs from NVD API
2. Apply macOS + Node.js filters
3. Isolate entries with CVSS >= 7.0
4. Cross-reference with GitHub Advisory
5. Report results in priority order

### 8.2 High-Level (Strategy Summary)

General approach summary. Which strategy works for which task type.

**Example:** "For CVE scanning, NVD API + GitHub Advisory cross-reference yields the most reliable results. A single source carries false-positive/negative risk."

### 8.3 Storage

Location: `$AEK_HOME/memory/trajectory-pool.json`

Each record conforms to this schema:

```json
{
  "id": "2026-02-28-researcher-cve-scan",
  "agent": "researcher",
  "task_type": "cve_scan",
  "strategy": "NVD API + web search cross-reference",
  "result": "SUCCESS",
  "failure_reason": null,
  "tokens_used": 12500,
  "duration_s": 45,
  "key_actions": ["NVD API query", "web_search verification"],
  "lessons": "NVD API applies rate limits during off-hours; use during business hours",
  "timestamp": "2026-02-28T14:30:00Z"
}
```

**Rules:**
- Every agent task is logged to the trajectory pool (successful or failed)
- Successful trajectories serve as in-context examples for similar future tasks
- Failed trajectories feed the Reflexion (Section 5) and Revision (Section 6) operators
- Weekly cleanup: keep the last 100 records, archive older ones to `$AEK_HOME/memory/trajectory-archive/`
- Trajectory matching: when a new task arrives, find the 3 closest trajectories by `task_type`
- Token budget: trajectories injected as in-context examples must be max 500 tokens (use summaries)

---

## 9. Metacognitive Reflection -- MARS Pattern

> Source: MARS (arxiv 2601.11974)

Two types of reflection are extracted from a single LLM call.

### 9.1 Principle Reflection (Normative)

"What rule should I follow to avoid repeating this mistake?"

Preventive, rule-based. Feeds the Prompt Evolution tactical stream (Section 7.1).

**Example:** "API calls should always have a retry mechanism. Do not mark as failed after a single attempt; make at least 3 attempts."

### 9.2 Procedure Reflection (Descriptive)

"What were the exact steps that led to success here?"

Repeatable, recipe-based. Feeds the Record & Replay low-level layer (Section 8.1).

**Example:** "1. Scrape GitHub trending page 2. Filter repos from the last 7 days 3. Sort by star growth rate 4. Summarize top 5"

### 9.3 Extraction Process

After task completion (successful or failed, for IMPORTANT tasks only):

```
Orchestrator sends a single reflection prompt to the agent:

"Evaluate this task:
1. PRINCIPLE: What RULE should be derived from this experience? (1-2 sentences)
2. PROCEDURE: What is the LIST of successful steps? (bullet points)
Write your answer under these two headings."
```

**Rules:**
- Both reflection types are extracted after every IMPORTANT task (trivial work excluded)
- A SINGLE LLM call is used (two separate calls are FORBIDDEN -- token waste)
- Principle --> added as a candidate rule to the Section 7 tactical stream
- Procedure --> recorded as a Section 8 low-level trajectory
- "Important task" definition: Quality=high OR failed OR took longer than 60s

**Reflection should NOT be triggered for:**
- Simple cron status checks
- Reminder deliveries
- Single-step deterministic operations

---

## 10. Heuristic + LLM Hybrid Evaluation

> Source: SE-Agent evaluation_function.py

A two-layer quality gate for agent outputs.

### 10.1 Layer 1 -- Cheap Heuristic Filter (ZERO cost)

Runs automatically on every agent output. Catches obvious issues with simple rules.

| Check               | Condition                                          | Action |
|----------------------|----------------------------------------------------|--------|
| Empty/short output   | < 50 characters (for important tasks)              | REJECT |
| Repetitive content   | 3+ consecutive similar paragraphs                  | REJECT |
| Unresolved error     | "failed", "unable", "error" + no solution          | FLAG   |
| Length check         | Within expected range for task type?               | FLAG   |
| Hallucination signals| Hedging language in critical data                  | FLAG   |
| Encoding corruption  | Non-UTF-8 characters or replacement blocks         | REJECT |

**Actions:**
- REJECT --> output is discarded, Revision (Section 6.1) is triggered
- FLAG --> output proceeds to Layer 2

### 10.2 Layer 2 -- LLM Evaluation (low cost)

Applied only to outputs that pass Layer 1 AND belong to important tasks.

**Model:** Use a fast, cheap model. Frontier models should NEVER be used for evaluation.

**Evaluation prompt:**

```
Rate this output on 3 dimensions (0-10 each):
1. RELEVANCE: How well does it address the question asked?
2. COMPLETENESS: Are there important missing points?
3. ACCURACY: Information correctness (for verifiable claims)

Total score: average of the 3 dimensions
```

**Score actions:**

| Score | Action                                                        |
|-------|---------------------------------------------------------------|
| 0-4   | REJECT --> trigger Revision, write failure to trajectory      |
| 5-7   | ACCEPT (flagged) --> present with "review may be needed" note |
| 8-10  | ACCEPT --> present directly to operator                       |

**Rules:**
- Layer 1 runs on EVERY agent output (no exceptions)
- Layer 2 runs only when:
  - Task importance is high (Quality=high)
  - Layer 1 issued a FLAG
  - Agent's last 3 reflections contain failures (low confidence)
- Layer 2 results are written to the trajectory pool (Section 8)
- Evaluation model is reviewed monthly (switch if a better/cheaper model is available)
- Evaluation time must NOT exceed 10% of total task time (overhead limit)

---

## Inter-Section Data Flow

```
Task Arrives (Routing)
  |
  +-- [19] Capability-Based Routing: Primary --> Secondary --> Fallback
  +-- [1]  Preference-Aware Routing: [Q,C,S] profile selects model

Task Failed
  |
  +-- [5]  Reflexion: write self-evaluation
  +-- [16] Reflexion v2: save to vector DB, RAG-inject into next attempt
  +-- [8]  Record & Replay: save failed trajectory
  +-- [9]  MARS: extract principle + procedure
  +-- [6]  Trajectory Evolution: trigger Revision
  +-- [7]  Prompt Evolution: add tactical rule (candidate)
  +-- [18] Circuit Breaker: update tool/API failure counter

Task Succeeded
  |
  +-- [8]  Record & Replay: save successful trajectory
  +-- [9]  MARS: extract procedure (principle optional)
  +-- [10] Evaluation: record score
  +-- [17] Maker-Checker: if quality-critical, send to checker

Knowledge Update
  |
  +-- [20] Bi-Temporal Memory: invalidate old, save new with timestamps

Weekly Evolution (Section 3)
  |
  +-- [21] Self-Improvement Cycle: collect metrics --> analyze --> hypothesize
  +-- [5]  Reflexion data       --> MEASURE
  +-- [8]  Trajectory pool      --> DIAGNOSE
  +-- [6]  Refinement operator  --> extract patterns
  +-- [7]  Strategic stream     --> PRESCRIBE
  +-- [10] Evaluation stats     --> MEASURE
  +-- [14] Autonomous Research  --> fill knowledge gaps
  +-- [13] Predictive Engine    --> next week forecast
  +-- [18] Circuit Breaker      --> report long-standing OPEN circuits

Autonomous Operations
  |
  +-- [22] Infrastructure Scripts: sandbox --> canary --> deploy
  +-- [12] Tool Generator: design --> generate --> test --> deploy
  +-- [11] Bridge: deep research, code writing, analysis
```

---

## 11. Bridge -- Full-Power LLM Access

> Script: `$AEK_HOME/scripts/bridge.sh`

The orchestrator accesses full LLM API power through a nested CLI interface. Every call is isolated, logged, and budget-controlled.

**Mechanism:** Spawn a nested LLM CLI session with environment isolation and prompt passthrough.

**Presets:**

| Preset     | Model Tier | Max Turns | Budget | Use Case                   |
|------------|------------|-----------|--------|----------------------------|
| --research | Frontier   | 50        | $2.00  | Deep research, analysis    |
| --quick    | Small      | 3         | $0.10  | Quick Q&A                  |
| --code     | Mid-tier   | 30        | $1.50  | Code generation            |
| --analyze  | Frontier   | 20        | $1.00  | Data analysis, patterns    |
| --tool-gen | Mid-tier   | 40        | $2.00  | Tool pipeline              |
| --system   | Mid-tier   | 15        | $0.50  | System management          |

**Rules:**
- Simple work --> use agent tools directly. Complex/creative/research --> use Bridge.
- Every call is logged to `$AEK_HOME/memory/bridge-logs/`.
- Bridge results are recorded in the relevant agent's trajectory pool.
- Budget overruns are prevented via `--max-budget`.
- Timeout support for long-running tasks (default 300s).

---

## 12. Tool Generator -- Autonomous Tool Creation

> Script: `$AEK_HOME/scripts/tool-gen.sh`

The orchestrator detects recurring needs and creates its own tools through a structured pipeline.

**5-Step Pipeline:**

```
1. DESIGN     --> Use Bridge (--quick) to generate a tool JSON spec
2. CODE       --> Use Bridge (--code) to write the script (bash/python/node)
3. TEST GEN   --> Generate an automated test script
4. TEST RUN   --> Execute tests, record results
5. CATALOG    --> Register in tools/catalog.json, deploy to tools/generated/
```

**Triggers:**
- Orchestrator performs the same task type a 2nd time --> "I should turn this into a tool"
- Weekly research identifies a new tool need
- Direct operator request

**Rules:**
- Every generated tool MUST be tested. If tests fail, it is NOT deployed.
- Tool catalog (`tools/catalog.json`) is the central registry of all tools.
- Usage count is tracked. Tools with 0 usage are cleaned up in monthly review.
- If a tool produces errors, reflexion + revision are triggered (integrated with Sections 5-6).

---

## 13. Predictive Engine

> Script: `$AEK_HOME/scripts/predict.sh`

A heuristic-based system that forecasts outcomes from past experience.

**4 Prediction Modes:**

| Mode          | Trigger                     | Output                              |
|---------------|-----------------------------|--------------------------------------|
| --weekly      | Weekly cron (Sunday)        | Weekly forecast report               |
| --task "type" | Before task execution       | Success probability + recommendation |
| --risk        | On demand                   | Risk analysis + preventive measures  |
| --opportunity | After weekly research       | Opportunity detection                |

**Data Sources:**
- `$AEK_HOME/memory/trajectory-pool.json` -- Task success/failure rates
- `$AEK_HOME/memory/reflections/` -- Lessons learned
- `$AEK_HOME/memory/knowledge/` -- Accumulated knowledge
- `$AEK_HOME/memory/evolution-log.md` -- Change history

**Prediction Model (Heuristic):**

```
Success estimate = (last_10_tasks * 0.6) + (last_30_tasks * 0.3) + (overall * 0.1)
Risk score = 1 - success_estimate + (reflection_count * 0.1)
```

**Rules:**
- Predictions are saved to `$AEK_HOME/memory/predictions/`.
- Weekly prediction accuracy is checked during the VERIFY step.
- If prediction accuracy drops, model parameters are adjusted.

---

## 14. Autonomous Research

> Script: `$AEK_HOME/scripts/research.sh`

The orchestrator's ability to conduct autonomous research for continuous self-improvement.

**4 Research Modes:**

| Mode             | Operation                                   | Output           |
|------------------|---------------------------------------------|------------------|
| --topic "topic"  | Research on a specific topic                | knowledge/ file  |
| --auto           | Select topic from trajectory failures       | knowledge/ file  |
| --trend          | Scan latest technology developments         | Trend report     |
| --gap-analysis   | Analyze knowledge gaps                      | Gap list         |

**Triggers:**
- **Cron:** Weekly (before self-evolution)
- **Reactive:** After recurring failures (--auto mode)
- **Proactive:** Orchestrator's decision ("My knowledge on this topic is stale")

**Topic Selection (--auto):**
1. Find the task type with the most failures in the trajectory pool
2. Analyze recurring issues from reflections
3. Select the topic with the highest improvement potential

**Rules:**
- Findings are saved as `$AEK_HOME/memory/knowledge/YYYY-MM-DD-<topic>.md`
- Research is logged in `$AEK_HOME/memory/research-log.md`
- Research results can be injected into relevant agent prompts (tactical rule candidate)
- Every research task is recorded in the trajectory pool

---

## 15. System Management

> Script: `$AEK_HOME/scripts/system-check.sh`

The orchestrator monitors and manages all system resources.

**Monitoring Areas:**

| Area              | Method/Command              | Frequency    |
|-------------------|-----------------------------|--------------|
| System info       | hostname, sw_vers, uptime   | On demand    |
| Disk status       | df, du                      | Daily        |
| Gateway process   | pgrep, lsof, launchctl      | Daily        |
| Agent sessions    | find sessions/*.jsonl       | Daily        |
| Cron/LaunchAgent  | crontab -l, launchctl       | On demand    |
| Self-evolution    | trajectory, reflections     | Weekly       |
| Cleanup           | Old archives, large logs    | Weekly       |

**Permission Matrix:**

| Operation                  | Autonomous | Approval Required |
|----------------------------|------------|-------------------|
| Read/analyze               | Yes        | -                 |
| Script creation            | Yes        | -                 |
| Cron scheduling            | Yes        | -                 |
| Package installation       | Yes        | -                 |
| File deletion              | -          | Yes               |
| System config change       | -          | Yes               |
| Externally-facing service  | -          | Yes               |

**Rules:**
- System check runs via daily cron.
- Critical alerts (disk >90%, gateway down) --> immediate operator notification.
- Cleanup suggestions are automatic; execution requires operator approval.

---

## 16. Reflexion Protocol v2 -- Vector DB Integration

> An enhanced version of the base Reflexion protocol (Section 5). Stores failure reflections in a vector database and retrieves them via RAG for subsequent attempts.

When an agent fails a task:

1. Agent writes a "Why did I fail?" reflection (natural language)
2. Save to vector DB: `category: "correction"`, `importance: 0.9`
3. On next attempt: RAG pulls semantically relevant failure reflections into context
4. Maximum 3 retry attempts, with reflection between each
5. After 3 failures: escalate to orchestrator (redirect or operator escalation)

**Record Format:**

```
REFLECTION: [agent] failed at [task] because [reason].
LESSON: [what should be done differently next time]
CONTEXT: [what the task was about]
```

**Difference from Section 5:** Section 5 is file-based (`$AEK_HOME/memory/reflections/`) with in-context injection. This section uses vector semantic search to find the CLOSEST failures -- even if the agent is on a different task, it catches similar mistakes.

**Rules:**
- Minimum 2s wait between retries (prevent immediately falling into the same error)
- Each reflection carries `agent`, `task_type`, `error_category` metadata in the vector DB
- RAG query: current task description + error message --> top-3 similar reflections
- On 3rd retry failure, orchestrator decides: redirect to a different agent OR escalate to operator

---

## 17. Maker-Checker Loop

A dual-agent verification loop for quality-critical outputs such as proposals, reports, and code.

**Flow:**

1. Maker agent produces the output
2. Checker agent (a DIFFERENT agent) evaluates against criteria
3. Score < threshold --> return to Maker with specific feedback
4. Maximum 3 iterations
5. If no iteration passes the threshold --> select the best version

**Default Pairings:**

| Maker                | Checker              | Use Case                              |
|----------------------|----------------------|---------------------------------------|
| content-agent        | analyst-agent        | Content quality, consistency, accuracy|
| researcher-agent     | security-agent       | Security-sensitive findings, CVE verification |
| social-media-agent   | content-agent        | Social media content, tone/language   |
| finance-agent        | security-agent       | Financial reports, risk assessment    |
| Any agent            | Orchestrator         | Strategic decisions, high-impact outputs |

**Threshold Values:**
- Content: Section 10 Layer 2 score >= 7
- Security: security-agent approve/reject (binary)
- Strategic: Orchestrator assessment >= 8

**Rules:**
- Checker and Maker CANNOT be the same agent (blind spot risk)
- Each iteration requires SPECIFIC feedback from Checker ("make it better" is FORBIDDEN)
- On 3rd iteration still below threshold: select highest-scored version + present with "review needed" flag
- Maker-Checker loops are recorded in the trajectory pool (Section 8): iteration count, final score
- Compatible with Section 5 Cross-Agent Critique Matrix: critique = lightweight version, Maker-Checker = heavyweight version

---

## 18. Circuit Breaker

A circuit breaker mechanism for tools or APIs that fail repeatedly.

**State Transitions:**

```
CLOSED (normal) --[error]--> counter++
  |                            |
  | (counter < 3)              | (counter >= 3)
  | <-- retry (backoff) -------+
  |                            |
  |                            v
  |                         OPEN (circuit open)
  |                            |
  |                            | (after 5 min)
  |                            v
  |                         HALF-OPEN (single probe)
  |                            |
  | <-- success ---------------+
  |                            |
  |                            +-- failure --> OPEN (again)
  |                                           + alert to orchestrator
```

**Retry Strategy:**
1. First failure: exponential backoff retry (1s, 2s, 4s)
2. 3 consecutive failures on the same tool: OPEN the circuit
3. Circuit open: skip the tool, use alternative or report incapability
4. After 5 minutes: HALF-OPEN, make a single probe attempt
5. Success --> CLOSE the circuit
6. Failure --> OPEN again, alert the orchestrator

**State Tracking:** `$AEK_HOME/memory/circuit-breaker-state.json`

```json
{
  "web_search": {
    "state": "CLOSED",
    "failures": 0,
    "last_failure": null,
    "opened_at": null
  },
  "nvd_api": {
    "state": "OPEN",
    "failures": 3,
    "last_failure": "2026-02-28T14:30:00Z",
    "opened_at": "2026-02-28T14:30:04Z"
  },
  "github_api": {
    "state": "HALF_OPEN",
    "failures": 3,
    "last_failure": "2026-02-28T14:25:00Z",
    "opened_at": "2026-02-28T14:25:06Z"
  }
}
```

**Rules:**
- Separate circuit breaker per tool/API endpoint
- State file is updated on every state change
- In OPEN state, use alternative tool if available (e.g., web_search OPEN --> use alternative scraper)
- Circuit breaker statistics are reported in weekly evolution (Section 3) MEASURE step
- Circuits OPEN for more than 24 hours --> operator notification (tool/API may have a persistent issue)

---

## 19. Capability-Based Routing Matrix

Task routing based on agent capabilities.

**Capability-Agent Mapping:**

| Capability          | Primary              | Secondary            | Fallback             |
|---------------------|----------------------|----------------------|----------------------|
| Web research        | researcher-agent     | analyst-agent        | Orchestrator (bridge)|
| Code analysis       | analyst-agent        | security-agent       | Bridge               |
| Content writing     | content-agent        | social-media-agent   | Orchestrator         |
| Financial analysis  | finance-agent        | analyst-agent        | researcher-agent     |
| System health       | security-agent       | Orchestrator         | monitor-agent        |
| Social media        | social-media-agent   | content-agent        | researcher-agent     |
| Security audit      | security-agent       | analyst-agent        | Orchestrator         |
| Trend detection     | researcher-agent     | social-media-agent   | analyst-agent        |

**Routing Decision Factors (in priority order):**

1. **Capability match** (required) -- can the agent perform this task type?
2. **Agent availability** -- is the agent currently idle? (active session check)
3. **Historical success rate** -- agent's success percentage for this task type in the trajectory pool
4. **Cost** -- for simple tasks, prefer the agent on a cheaper model

**Routing Flow:**

```
Task arrives
  |
  +-- Determine task type (research? code? content? finance? security?)
  |
  +-- Is primary agent available?
  |    +-- YES --> Is primary's success rate for this task type >= 70%?
  |    |    +-- YES --> Route to primary
  |    |    +-- NO  --> Route to secondary (with success rate check)
  |    +-- NO  --> Is secondary available?
  |         +-- YES --> Route to secondary
  |         +-- NO  --> Route to fallback (usually Bridge)
  |
  +-- None suitable --> Queue, route to first available suitable agent
```

**Rules:**
- If Fallback = Bridge, apply cost controls (Section 11 budget limits)
- Success rate is calculated from the trajectory pool (Section 8)
- New task type (no trajectory records) --> route to primary, record result as baseline
- Agent fails 3 consecutive times on the same type --> temporarily disabled for that type (reviewed weekly)

---

## 20. Bi-Temporal Memory

Every piece of information stored in the vector database tracks two time dimensions.

**Fields:**
- `valid_from`: date when the information became true (when it started being correct)
- `invalid_at`: date when the information became invalid (when it stopped being correct; `null` if still valid)

**When new information conflicts with old:**

1. Set the old record's `invalid_at` to `now`
2. Save the new record with `valid_from = now`
3. Link to the old record via the `supersedes` field

**Example:**

```json
// Old record (now invalid)
{
  "content": "Gateway uses port 28643",
  "valid_from": "2026-01-15T00:00:00Z",
  "invalid_at": "2026-02-20T14:00:00Z",
  "superseded_by": "mem_20260220_port_change"
}

// New record (current)
{
  "id": "mem_20260220_port_change",
  "content": "Gateway uses port 28643 (WS) + 28645 (HTTP)",
  "valid_from": "2026-02-20T14:00:00Z",
  "invalid_at": null,
  "supersedes": "mem_20260115_port"
}
```

**Rules:**
- NEVER delete -- invalidate. History is valuable for pattern detection.
- RAG queries by default return only records where `invalid_at = null`
- For historical analysis (e.g., "When did this change?"), the full time series can be queried
- Follow the `supersedes` chain to trace a piece of knowledge's evolution
- Migration: existing records are updated with `valid_from = created_at`, `invalid_at = null`

---

## 21. Self-Improvement Cycle

> Script: `$AEK_HOME/scripts/weekly-cycle.sh`
> Schedule: Weekly (e.g., every Sunday at 22:00)

An automated weekly performance analysis and improvement loop.

**5-Step Cycle:**

```
1. COLLECT
   - Gather weekly metrics via metrics script
   - Per agent: task count, success rate, average duration, cost

2. IDENTIFY
   - Find the agent with the lowest success rate
   - List failed tasks from the Section 8 trajectory pool

3. ANALYZE
   - Extract failure patterns (which task types, at which times, with which tools)
   - Group recurring causes from Reflections (Sections 5, 16)

4. HYPOTHESIZE
   - Generate 1-3 improvement hypotheses
   - For each: expected impact, implementation cost, risk level

5. IMPLEMENT
   - Select the SMALLEST and LOWEST risk hypothesis
   - Apply it (prompt change or config adjustment)
   - Monitor next week's metrics (Section 3, VERIFY step)
```

**Rules:**
- Integrated with Section 3 (Self-Evolution) -- this section handles automatic data collection and analysis; Section 3 handles decisions and application
- Hypothesis implementation requires operator approval (Section 3 rule)
- Weekly report saved as `$AEK_HOME/memory/weekly-reports/YYYY-WW.md`
- If an agent's metrics degrade for 3 consecutive weeks --> orchestrator raises a proactive warning

---

## 22. Autonomous Infrastructure Scripts

Scripts available to the orchestrator for autonomous infrastructure management.

| Script                | Operation                                 | Use Case                      |
|-----------------------|-------------------------------------------|-------------------------------|
| `sandbox.sh`          | 3-layer extension test (load/typecheck/canary) | MANDATORY before deploy  |
| `validate-plugin.mjs` | Layer 1: runtime load + mock register     | Core of sandbox               |
| `canary-deploy.sh`    | Monitored deploy + automatic rollback     | Production changes            |
| `watchdog.sh`         | 4-tier self-healing gateway monitoring    | Runs continuously (60s)       |
| `metrics.sh`          | Per-agent performance tracking            | Daily + weekly                |
| `briefing.sh`         | Tri-phase daily briefing                  | Morning/midday/evening        |
| `goal-decompose.sh`   | HTN goal tracking and decomposition       | Strategic planning            |
| `skill-discovery.sh`  | Capability gap detection                  | Weekly analysis               |

All scripts reside in `$AEK_HOME/scripts/`.

**Usage Rules:**

1. **Sandbox-first:** Test with `sandbox.sh` before any deploy. Failed sandbox --> do NOT deploy.
2. **Canary deploy:** Direct deploy is FORBIDDEN. Always start with canary; if metrics are clean, proceed to full deploy.
3. **Watchdog integration:** Check watchdog status before any gateway-related operation.
4. **Metric tracking:** Every autonomous operation's result is recorded via `metrics.sh`.
5. **Script-first:** If a script exists for a task, use it FIRST. Manual operation is a last resort.

**Priority Flow:**
```
Does a script exist for this task?
  +-- YES --> Use the script
  +-- NO  --> Perform manually + evaluate creating a script (Section 12)
```

---

## 23. Sandbox Pipeline

> Scripts: `$AEK_HOME/scripts/sandbox.sh`, `$AEK_HOME/scripts/validate-plugin.mjs`

A 3-layer pre-deployment testing pipeline for extensions and plugins.

### Pipeline Layers

```
LAYER 1: Runtime Load + Mock Register (~200ms)
  | Uses the platform's own runtime loader to load the extension
  | Calls register() with a mock API, checks tool/service counts
  | Catches: syntax errors, import errors, runtime exceptions, registration failures
  |
  +-- PASS --> Proceed to Layer 2
  +-- FAIL --> STOP. Do NOT deploy. Fix the error, retry.

LAYER 2: Type Check (~2.5s)
  | TypeScript type checker scans for type errors
  | For platform extensions: ADVISORY (runtime strips types, type errors don't crash)
  | Catches: type mismatch, interface incompatibility, generic type errors
  |
  +-- PASS --> Proceed
  +-- ADVISORY --> Warnings reported but counted as PASS
  +-- FAIL (non-extension) --> STOP. Do NOT deploy.

LAYER 3: Canary Deploy (~30s)
  | Real-environment canary test via canary-deploy script
  | 60-second monitoring, ERROR/FATAL/CRASH pattern scanning
  | Failure --> automatic rollback
  | Catches: integration errors, dependency conflicts, runtime crashes
  |
  +-- PASS --> Deploy successful
  +-- FAIL --> Automatic rollback. Investigate the error.
```

**Rules:**
- Layer 1 FAIL --> NEVER deploy. Syntax/runtime errors will crash production.
- Layer 2 FAIL (non-extension) --> do not deploy. Type errors can corrupt runtime behavior.
- Layer 2 ADVISORY (platform extension) --> deployable. The runtime does not enforce types.
- Layer 3 FAIL --> canary automatically rolls back. Investigate, fix, retry.
- Every sandbox test runs on an isolated copy in temp directory -- source files are UNTOUCHED.

---

## 24. Extension Development Lifecycle

A summarized lifecycle for developing new extensions within the platform.

**Flow:**

```
1. NEED IDENTIFICATION
   | Recurring task detection (Section 12)
   | Skill gap analysis (skill-discovery.sh)
   | Operator request
   v
2. DESIGN
   | Define extension spec: tools, hooks, CLI commands
   | Define config requirements via schema
   v
3. CODE
   | Write in TypeScript
   | Export: {id, name, description, kind, configSchema, register}
   | register(api) contains: registerTool(), on(), registerCli(), etc.
   v
4. SANDBOX TEST
   | Run Layer 1 (fast check, ~200ms)
   | Pass --> Run Layer 1 + Layer 2
   | Pass --> Proceed to deploy
   | Fail --> Fix, retry (max 5 iterations)
   v
5. DEPLOY
   | Copy files to platform extensions directory
   | Backup to local patch directory
   | Restart gateway, monitor for 60s
   v
6. VERIFY
   | Extension loaded? (check logs for registration message)
   | Tools available? (visible in gateway tool list)
   | No errors? (60s monitoring clean)
   | FAILURE --> rollback from backup, restart gateway
```

**Debugging Reference:**

| Error Type         | Symptom                              | Resolution                           |
|--------------------|--------------------------------------|--------------------------------------|
| Syntax error       | `ParseError: Unexpected token`       | Fix TS syntax at indicated line      |
| Missing import     | `Cannot find module 'xxx'`           | Add correct import or check deps     |
| Runtime error      | `TypeError: Cannot read properties`  | Add null/undefined checks            |
| Config validation  | `apiKey is required`                 | Create sandbox config or add to known configs |
| Registration fail  | `Module does not export...`          | Verify default export structure      |
| Type error         | `error TS2307/TS2769`                | Extension: advisory. Other: fix type |

---

## 25. Full Power Operation Matrix

A summary matrix of all orchestrator capabilities and when to use each.

### 25.1 Autonomous Capabilities (No Approval Required)

| Capability           | Section | Script/Mechanism       | When                     |
|----------------------|---------|------------------------|--------------------------|
| Extension testing    | 23      | sandbox.sh             | After code changes       |
| Extension loading    | 23      | validate-plugin.mjs    | Quick check              |
| Gateway monitoring   | 22      | watchdog.sh            | Continuous (60s interval)|
| Performance metrics  | 22      | metrics.sh             | After every task         |
| Briefing preparation | 22      | briefing.sh            | Morning/midday/evening   |
| Goal tracking        | 22      | goal-decompose.sh      | Strategic planning       |
| Skill gap analysis   | 22      | skill-discovery.sh     | Weekly                   |
| Reflexion writing    | 5, 16   | Vector DB + file       | After failure            |
| Trajectory recording | 8       | trajectory-pool.json   | Every task               |
| Circuit breaker      | 18      | state.json             | On API error             |
| Research             | 14      | research.sh            | Knowledge gap detected   |
| Tool generation      | 12      | tool-gen.sh            | Recurring need           |
| Prediction           | 13      | predict.sh             | Weekly + pre-task        |
| Bridge calls         | 11      | bridge.sh              | Complex research/code    |

### 25.2 Operations Requiring Approval

| Operation                        | Reason                     | Escalation Path        |
|----------------------------------|----------------------------|------------------------|
| Extension deploy (elevated perms)| Requires elevated access   | Ask operator           |
| Gateway restart                  | Service interruption       | Watchdog or operator   |
| Config change                    | System-wide impact         | Operator approval      |
| Prompt evolution application     | Changes agent behavior     | Weekly review          |
| New cron/LaunchAgent             | Persistent system change   | Operator approval      |

### 25.3 Decision Tree: "What Should I Do?"

```
I need to write a new extension
  +-- Section 24: Design --> Code --> Sandbox Test --> Deploy

I need to update an existing extension
  +-- Section 24: Temp copy --> Changes --> Sandbox --> Deploy

Something broke, gateway crashed
  +-- Watchdog auto-detects (Section 22)
  +-- L3 attempts auto-restart
  +-- Failed --> L4 alert + escalate to operator

A new tool is needed
  +-- Section 12: Tool Generator Pipeline
  +-- Sandbox test mandatory (Section 23)

An agent failed
  +-- Write Reflexion (Sections 5, 16)
  +-- Record trajectory (Section 8)
  +-- Try Revision (Section 6)
  +-- Still failing --> escalate

Weekly review time
  +-- Self-Improvement Cycle (Section 21)
  +-- Collect metrics --> analyze --> hypothesize --> apply

I lack knowledge on a topic
  +-- Autonomous Research (Section 14)
  +-- Deep research via Bridge (Section 11)
```

---

## References

1. **ToolOrchestra** -- Preference-aware routing, composite reward
   [arxiv.org/abs/2511.21689](https://arxiv.org/abs/2511.21689)

2. **AgentOrchestra** -- TEA protocol, agent-as-tool, self-evolution
   [arxiv.org/abs/2506.12508](https://arxiv.org/abs/2506.12508)

3. **SE-Agent** -- Trajectory evolution (revision, recombination, refinement)
   [arxiv.org/abs/2508.02085](https://arxiv.org/abs/2508.02085)

4. **Reflexion** -- Verbal self-reflection, in-context learning from failures
   [arxiv.org/abs/2303.11366](https://arxiv.org/abs/2303.11366)

5. **MAR (Multi-Agent Reflexion)** -- Cross-agent critique, multi-agent review
   [arxiv.org/abs/2512.20845](https://arxiv.org/abs/2512.20845)

6. **SCOPE** -- Dual-stream prompt optimization (tactical + strategic)
   [arxiv.org/abs/2512.15374](https://arxiv.org/abs/2512.15374)

7. **AgentRR (Record & Replay)** -- Two-level experience storage, trajectory replay
   [arxiv.org/abs/2505.17716](https://arxiv.org/abs/2505.17716)

8. **MARS (Metacognitive Reflection)** -- Principle + procedure reflection extraction
   [arxiv.org/abs/2601.11974](https://arxiv.org/abs/2601.11974)

9. **SimpleMem** -- Memory-augmented agents, simple retrieval patterns
   [arxiv.org/abs/2601.02553](https://arxiv.org/abs/2601.02553)

10. **Evolving Orchestration** -- Self-evolving multi-agent orchestration
    [arxiv.org/abs/2505.19591](https://arxiv.org/abs/2505.19591)
