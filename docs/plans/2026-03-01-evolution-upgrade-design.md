# Evolution Upgrade Design — Production-First + relay Pattern Integration

**Date:** 2026-03-01
**Status:** APPROVED
**Approach:** Fix-First, Enrich-Later (Approach A)
**Stack:** Bash/Markdown/Python only (no new compiled dependencies)

---

## Context

### Current State (Audit: 2026-03-01)

| Category | Count | Details |
|----------|-------|---------|
| Fully implemented (YES) | 4/17 | Prompt Evolution, Cognitive Memory FSRS-6, Bridge.sh, Research Engine |
| Partial (PARTIAL) | 6/17 | Reflexion (0 files), Trajectory Pool (1 entry, JSON bug), Predictive Engine (1 manual run), Weekly Cycle (never triggered), Capability Routing (static), Trust Score (rate limit only) |
| Not implemented (NO) | 7/17 | Circuit Breaker, Cross-Agent Critique, MARS, Maker-Checker, AgentRR, Hybrid Evaluation, 5-Level Autonomy |
| **Implementation rate** | **~41%** | Down from self-assessed 65-70% |

### Critical Bug

`oracle-bridge.sh` line 220-234: Python trajectory append code expects flat array (`json.load(f)` → list), but `trajectory-pool.json` is dict format (`{"_schema_version":"1.0","entries":[...]}`). Bridge silently fails or overwrites schema metadata. 9+ bridge calls produced 0 trajectory entries.

### relay Analysis (AgentWorkforce/relay)

Source of pattern inspiration. Key adoptable patterns:
- 24 Swarm Patterns (YAML-driven orchestration)
- Consensus Engine (5 voting types)
- Supervisor RestartPolicy (parameterized crash recovery)
- Crash Insights (pattern categorization + health score)
- Priority Queue (P0-P4 task prioritization)
- Shadow Agent (observer pattern with speak-on triggers)
- Context Compaction (importance scoring)

---

## Phase 1: Critical Fixes (Foundation)

### 1.1 Trajectory Pool JSON Bug Fix

**File:** `scripts/oracle-bridge.sh` (lines 220-234)

**Problem:** Python code does `pool = json.load(f)` expecting list, file is dict with `entries` key.

**Fix:**
```python
raw = json.load(f)
if isinstance(raw, dict):
    pool = raw.get("entries", [])
    schema = {k: v for k, v in raw.items() if k != "entries"}
else:
    pool = raw
    schema = {"_schema_version": "1.0", "_max_entries": 100}
pool.append(entry)
pool = pool[-100:]  # retain last 100
schema["entries"] = pool
json.dump(schema, f, indent=2)
```

**Additional:** Change hardcoded `result: "success"` to derive from bridge exit code (0=success, non-zero=error).

**Impact:** Every bridge call produces a trajectory entry. All downstream systems (predict, reflexion, routing) get data.

### 1.2 Circuit Breaker State Machine

**New script:** `oracle-circuit-breaker.sh`

**Commands:**
- `circuit-breaker.sh check <agent|tool>` — returns CLOSED/OPEN/HALF-OPEN
- `circuit-breaker.sh trip <agent|tool>` — force OPEN
- `circuit-breaker.sh reset <agent|tool>` — force CLOSED
- `circuit-breaker.sh status` — dashboard of all breakers

**State file:** `memory/circuit-breaker-state.json`
```json
{
  "breakers": {
    "researcher-agent": {
      "state": "CLOSED",
      "failure_count": 0,
      "last_failure": null,
      "last_state_change": "2026-03-01T10:00:00Z",
      "consecutive_failures": 0,
      "config": {"threshold": 3, "cooldown_seconds": 300, "probe_timeout": 60}
    }
  }
}
```

**State transitions:**
- CLOSED → OPEN: 3 consecutive failures
- OPEN → HALF-OPEN: after cooldown (default 5min)
- HALF-OPEN → CLOSED: probe succeeds
- HALF-OPEN → OPEN: probe fails

**Integration:** Bridge checks circuit breaker before every call. OPEN → reject with reason.

### 1.3 Reflexion Trigger

**Integration point:** `oracle-bridge.sh` post-execution hook

**Logic:**
```
if bridge_exit_code != 0:
    reflection_prompt = "Analyze this failure: {task}, {error_output}. What went wrong? Root cause? Lesson for future?"
    reflection = bridge_call(haiku, reflection_prompt, max_tokens=300)
    save to memory/reflections/{agent}/YYYY-MM-DD-{topic}.md
    append lesson to trajectory entry
```

**Trigger conditions:**
1. Bridge call fails (exit code != 0)
2. 2+ recent failures for same agent (from trajectory pool)
3. Manual: `--reflect` flag

**Cost control:** Haiku model, max 300 tokens, skip if same agent reflected in last hour.

---

## Phase 2: Implement Missing Features

### 2.1 Hybrid Evaluation

**New script:** `oracle-eval.sh`

**Layer 1 (Heuristic, zero cost):** Python helper checks:
1. Empty output (< 10 chars)
2. Repetitive content (3+ identical sentences, Jaccard > 0.8)
3. Unresolved error patterns ("Error:", "Exception:", "FAILED")
4. Length violation (configurable min/max per task type)
5. Hallucination indicators ("I don't have access", "As an AI")
6. Encoding corruption (null bytes, broken UTF-8)
7. Missing required fields (task-type specific)
8. Stale data references (dates > 30 days old in time-sensitive tasks)

Score: 0-100. Each check weighted equally (12.5 points each).

**Layer 2 (LLM, cheap model):** Only if Layer 1 score is 40-80 (gray zone).
- Single bridge call (haiku): Rate Relevance/Completeness/Accuracy 0-10
- Combined: `(R*0.4 + C*0.3 + A*0.3) * 10`
- < 40 = REJECT, 40-70 = ACCEPT+flag, > 70 = ACCEPT

**Integration:** Bridge post-execution → Layer 1 → (optional Layer 2) → write eval_score to trajectory.

### 2.2 Maker-Checker Loop

**New script:** `oracle-maker-checker.sh`

**Usage:** `oracle-maker-checker.sh --maker <agent> --checker <agent> --task "description" --input <file>`

**Flow:**
1. Read maker output from file
2. Send to checker agent via bridge with review prompt
3. Parse response: APPROVE / ISSUE(feedback) / REJECT(reason)
4. If ISSUE: send feedback to maker via bridge, get revised output, back to step 2
5. Max 3 iterations. If still ISSUE after 3 → escalate to orchestrator.

**Pairing config:** `config/maker-checker-pairs.yaml`
```yaml
pairs:
  - maker: content-agent
    checker: analyst-agent
    domains: [blog, documentation, report]
    threshold: 7
  - maker: researcher-agent
    checker: security-agent
    domains: [code-review, api-design]
    threshold: 8
  - maker: "*"
    checker: orchestrator
    domains: ["*"]
    threshold: 7
```

**Trigger:** HIGH importance tasks (from priority system) auto-trigger. Manual with `--force`.

### 2.3 MARS Metacognitive Extraction

**Integration:** Post-reflexion hook in bridge

**Logic:** After a reflection is written (Phase 1.3), make one additional bridge call:
```
Given this reflection: {reflection_content}
Extract:
1. PRINCIPLE: A normative rule ("Always X when Y because Z")
2. PROCEDURE: Descriptive steps taken ("Step 1: ..., Step 2: ...")
```

**Storage:**
- Principle → append to `memory/principles/{agent}.md` (input for prompt evolution tactical stream)
- Procedure → write to trajectory entry `low_level_steps` field (input for Record & Replay)

**Cost:** 1 haiku call per reflection. Skip if reflection < 50 words.

### 2.4 AgentRR Record & Replay

**New script:** `oracle-replay.sh`

**Record:** Already handled by trajectory pool (Phase 1.1 fix). Enhanced with MARS procedures (Phase 2.3).

**Replay logic:**
```
oracle-replay.sh --task-type "code-review" --max-examples 3 --max-tokens 500
```
1. Search trajectory pool for matching `task_type`
2. Sort by: SUCCESS first, then by recency
3. Select top 3 (at least 1 FAILURE if available for contrast)
4. Format as in-context examples (max 500 tokens each)
5. Output to stdout (bridge pipes into prompt)

**Bridge integration:** `--replay` flag activates replay injection before task prompt.

### 2.5 5-Level Autonomy Enforcement

**Config:** `config/autonomy-levels.yaml`
```yaml
levels:
  L1_reactive:
    trust_min: 0
    allowed: [read, search, respond_to_human]
    requires_approval: [write, execute, delegate]
  L2_scheduled:
    trust_min: 500
    allowed: [read, search, respond_to_human, execute_cron, run_known_scripts]
    requires_approval: [write_code, delegate, tool_create]
  L3_self_monitoring:
    trust_min: 600
    allowed: [L2 + watchdog_restart, circuit_breaker, alert, self_diagnose]
    requires_approval: [prompt_modify, agent_config_change]
  L4_self_improving:
    trust_min: 900
    allowed: [L3 + reflexion, prompt_evolution, trajectory_learning, maker_checker]
    requires_approval: [tool_synthesis, agent_spawn, governance_change]
  L5_autonomous:
    trust_min: 1000
    allowed: [all]
    requires_approval: [governance_change, trust_modification]
    note: "Future — not yet active"
```

**Enforcement:** `oracle-governance.sh` checks autonomy level before bridge calls.

**Dynamic adjustment:**
- 10 consecutive successes → suggest level +1 (operator approval required)
- 3 consecutive failures → automatic level -1 (immediate, logged)
- Trust score changes update level assignment automatically

---

## Phase 3: relay Pattern Integration

### 3.1 Swarm Pattern Catalog

**Directory:** `config/swarm-patterns/`

**Priority 8 patterns (implemented):**

| Pattern | YAML | Use Case |
|---------|------|----------|
| reflection | `reflection.yaml` | Self-critique loop |
| review-loop | `review-loop.yaml` | Generalized maker-checker |
| red-team | `red-team.yaml` | Adversarial testing |
| consensus | `consensus.yaml` | Multi-agent voting |
| pipeline | `pipeline.yaml` | Sequential A→B→C |
| fan-out | `fan-out.yaml` | Parallel same-task |
| escalation | `escalation.yaml` | Cheap→expensive model cascade |
| circuit-breaker | `circuit-breaker.yaml` | CB-wrapped execution |

**Remaining 16 patterns:** Documented in `docs/swarm-patterns.md` with YAML templates but not runner-implemented.

**Runner:** `oracle-swarm.sh`
```bash
oracle-swarm.sh --pattern consensus --config task-config.yaml
oracle-swarm.sh --pattern pipeline --agents "researcher,analyst,writer" --task "Research and write report on X"
```

### 3.2 Consensus Engine

**File:** `scripts/helpers/consensus.py`

**Input:** JSON votes array
**Output:** JSON result with decision, vote counts, consensus type

**5 types:**
- `majority`: > 50% agreement
- `supermajority`: > 66% agreement
- `unanimous`: 100% agreement
- `weighted`: Sum of weights per option, highest wins
- `quorum`: Minimum N participants + majority among them

**Features:** Early termination (when result is mathematically certain), tie-breaking (orchestrator decides), expiry (timeout → no consensus → escalate).

### 3.3 Supervisor Restart Policy

**Enhancement to:** `oracle-watchdog.sh`

**Config:** `config/restart-policies.yaml`
```yaml
agents:
  gateway:
    max_restarts: 5
    max_consecutive_failures: 3
    cooldown_seconds: 2
    backoff: exponential
    max_backoff: 60
    permanently_dead_action: alert_operator
  default:
    max_restarts: 3
    max_consecutive_failures: 2
    cooldown_seconds: 5
    backoff: linear
    max_backoff: 30
    permanently_dead_action: log_only
```

**State:** `memory/supervisor-state.json`
**Stability reset:** 5 min stable → reset consecutive failure counter

### 3.4 Crash Insights

**Enhancement to:** `oracle-agent-health.sh`

**Crash categories:** OOM, Segfault, Timeout, ConfigError, GenericError
**Pattern detection:** Regex on log output
**Health score:** `100 - (recent_crashes * 20) - (slow_restart_penalty) - (consecutive_fail * 10) - (cb_open_penalty)`
**Storage:** `memory/crash-insights.json`
**Integration:** Briefing shows health scores, predict.sh uses for risk analysis

### 3.5 Priority Queue

**Config:** `config/priority-rules.yaml`

**5 levels:** P0 (Critical) → P4 (Background)
**Auto-assignment:** Keyword matching on task description
**Drop policy:** Queue > 20 → drop P4, > 30 → drop P3. P0-P1 never dropped.
**Integration:** Goal-decompose assigns priority. Bridge accepts `--priority` flag.

### 3.6 Shadow Agent

**Config:** `config/shadow-agents.yaml`

**Modes:** passive (log only), review (post-task review), active (real-time intervention)
**Triggers:** code_written, security_risk, task_complete, error, all
**Cost control:** Max 5 shadow reviews/day, haiku model
**Storage:** `memory/shadow-reviews/`

---

## Phase 4: Repo Sync

### New Files for Public Repo

**Scripts (6):**
- `scripts/circuit-breaker.sh`
- `scripts/eval.sh`
- `scripts/maker-checker.sh`
- `scripts/swarm.sh`
- `scripts/replay.sh`
- `scripts/helpers/consensus.py`

**Configs (6):**
- `config/swarm-patterns/*.yaml` (8 files)
- `config/restart-policies.example.yaml`
- `config/priority-rules.example.yaml`
- `config/shadow-agents.example.yaml`
- `config/autonomy-levels.example.yaml`
- `config/maker-checker-pairs.example.yaml`

**Docs (4 new + 6 updated):**
- NEW: `docs/swarm-patterns.md`, `docs/consensus-engine.md`, `docs/shadow-agent.md`, `docs/priority-queue.md`
- UPDATED: circuit-breaker.md, maker-checker.md, hybrid-evaluation.md, autonomy-layers.md, record-and-replay.md, metacognitive-reflection.md

**README.md:** Updated differentiator table, core concepts, repo tree.

### Sanitization Checklist
- Zero matches for: Mahsum, clawd, openclaw, CikCik, Soros, Tithonos, Hachiko, Oracle
- All scripts pass `bash -n`
- All internal links valid
- No hardcoded secrets/paths

---

## Expected Outcome

| Metric | Before | After |
|--------|--------|-------|
| Full implementation | 4/17 (24%) | 14/17 (82%) |
| Partial | 6/17 | 3/17 |
| Not implemented | 7/17 | 0/17 |
| **Implementation rate** | **~41%** | **~88%** |
| Scripts | 10 | 16 (+consensus.py) |
| Config files | 2 | ~14 |
| Repo files | 54 | ~75 |
| relay patterns adopted | 0 | 7 |

### Remaining PARTIAL after upgrade (future work)
1. Capability Routing — weighted/dynamic routing needs trajectory data accumulation
2. 5-Level Autonomy L5 — ML routing and tool synthesis (future)
3. AgentRR Replay — embedding-based similarity search (needs vector DB, future)
