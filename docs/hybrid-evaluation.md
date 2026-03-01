# Hybrid Evaluation

Two-layer quality gate for agent outputs. Layer 1 is a zero-cost heuristic filter that runs on every output. Layer 2 is a low-cost LLM evaluation that runs only when needed. This layered approach keeps evaluation costs near zero for routine outputs while catching quality issues on important tasks.

## Overview

Not every agent output needs LLM-based evaluation — most can be validated with simple heuristic checks. Hybrid Evaluation applies the cheapest sufficient check first and escalates to LLM evaluation only when heuristics are insufficient or when the task is important enough to warrant the cost.

## Layer 1 — Heuristic Filter (Zero Cost)

Runs automatically on every agent output. No LLM calls, no API costs. Pure programmatic checks.

### Check Table

| Check | Condition | Action | Rationale |
|-------|-----------|--------|-----------|
| Empty or short output | Less than 50 characters for a non-trivial task | REJECT | Agent likely failed silently |
| Repetitive content | 3 or more similar consecutive paragraphs (>80% overlap) | REJECT | Generation loop or degenerate output |
| Unresolved error | Contains "failed", "unable", "error" without a proposed solution | FLAG | Agent reported a problem but did not address it |
| Length violation | Output length outside expected range for task type | FLAG | May indicate truncation or over-generation |
| Hallucination indicators | "I think", "probably", "might be wrong" in data that should be factual | FLAG | Low-confidence claims in critical data fields |
| Encoding corruption | Non-UTF-8 characters or Unicode replacement characters (U+FFFD) | REJECT | Corrupted data should never propagate |
| Missing required fields | Task-specific required fields absent from output | REJECT | Incomplete output is unusable |
| Stale data markers | Dates older than expected freshness window | FLAG | Data may be outdated |

### Actions

- **REJECT**: Output is discarded immediately. A Revision is triggered (see `trajectory-learning.md`). The rejection reason is logged in the trajectory pool.
- **FLAG**: Output is not discarded but is marked for further review. If Layer 2 is enabled for this task, the flagged output proceeds to LLM evaluation. If Layer 2 is not enabled, the flag is logged and the output is accepted with a review marker.

### Customization

Each agent can define additional heuristic checks relevant to its domain:

```json
{
  "agent": "finance-agent",
  "custom_checks": [
    {
      "name": "currency_format",
      "condition": "Financial figures without currency symbol",
      "action": "FLAG"
    },
    {
      "name": "date_presence",
      "condition": "Financial data without reference date",
      "action": "REJECT"
    }
  ]
}
```

## Layer 2 — LLM Evaluation (Low Cost)

Uses a cheap, fast model to evaluate output quality on three dimensions. Never uses an expensive model for evaluation — the evaluation cost must remain a small fraction of the task cost.

### When Layer 2 Runs

Layer 2 is activated when any of these conditions are met:

| Condition | Rationale |
|-----------|-----------|
| Task importance is HIGH | Important outputs justify evaluation cost |
| Layer 1 flagged the output | Heuristics detected a potential issue |
| Agent has 2+ recent failures | Agent in a failure pattern needs closer monitoring |
| Output will be published externally | External-facing content has higher quality requirements |

Layer 2 does NOT run when:
- Task is trivial (status checks, simple lookups)
- Layer 1 passed cleanly and task importance is LOW or MEDIUM
- Evaluation time would exceed 10% of total task time

### Evaluation Prompt

```
You are evaluating an agent's output for quality.

Task description: [task]
Agent output: [output]

Rate this output 0-10 on each dimension:

1. RELEVANCE: How well does the output answer the original question or fulfill the task?
   (0 = completely off-topic, 10 = perfectly addresses the task)

2. COMPLETENESS: Are all important points covered?
   (0 = missing critical information, 10 = comprehensive with no gaps)

3. ACCURACY: Is the information correct? (For verifiable claims only)
   (0 = contains factual errors, 10 = all claims are accurate)

Provide scores as: RELEVANCE: X, COMPLETENESS: Y, ACCURACY: Z
```

### Score Interpretation

The final score is the average of the three dimension scores.

| Score Range | Action | Description |
|-------------|--------|-------------|
| 0-4 | REJECT | Output is fundamentally flawed. Trigger Revision. |
| 5-7 | ACCEPT with review flag | Output is usable but imperfect. Log the flag for the orchestrator. |
| 8-10 | ACCEPT | Output meets quality standards. No further action needed. |

### Dimension Weights

By default, all three dimensions are equally weighted. Agents can override weights for their domain:

```json
{
  "agent": "researcher-agent",
  "eval_weights": {
    "relevance": 0.3,
    "completeness": 0.3,
    "accuracy": 0.4
  }
}
```

For research tasks, accuracy matters more. For creative tasks, relevance and completeness may matter more than strict accuracy.

## Evaluation Flow

```
Agent produces output
  |
  v
Layer 1: Heuristic Filter (always runs, zero cost)
  |
  ├── REJECT --> Discard output, trigger Revision, log rejection
  |
  ├── FLAG --> Proceed to Layer 2 check
  |
  └── PASS --> Check if Layer 2 is needed
                |
                ├── Task importance HIGH, or agent has recent failures
                |     |
                |     v
                |   Layer 2: LLM Evaluation (low cost)
                |     |
                |     ├── Score 0-4 --> REJECT, trigger Revision
                |     ├── Score 5-7 --> ACCEPT with review flag
                |     └── Score 8-10 --> ACCEPT
                |
                └── Task importance LOW/MEDIUM, no recent failures
                      |
                      v
                    ACCEPT (Layer 1 sufficient)
```

## Cost Guardrails

Evaluation must not become a significant cost center:

1. **Layer 1 first, always.** Most outputs are caught or cleared by heuristics alone.
2. **Cheap model for Layer 2.** Use the fastest, cheapest available model. Evaluation does not require frontier-level reasoning.
3. **10% rule.** If the evaluation would take more than 10% of the total task time, skip Layer 2 and accept with the Layer 1 result.
4. **No recursive evaluation.** Never evaluate the evaluation. If Layer 2 produces a score, that score is final.
5. **Batch when possible.** If multiple outputs need Layer 2 evaluation, batch them into a single LLM call.

## Logging

All evaluation results are logged:

```
[2026-02-28 14:30] researcher-agent | Layer 1: PASS | Layer 2: 8.3 ACCEPT
[2026-02-28 14:35] content-agent   | Layer 1: FLAG (hallucination indicator) | Layer 2: 5.7 ACCEPT+FLAG
[2026-02-28 14:40] analyst-agent   | Layer 1: REJECT (empty output) | Revision triggered
```

## Integration Points

- **Input:** Agent task outputs
- **Output:** ACCEPT, ACCEPT+FLAG, or REJECT decisions
- **Output:** Rejection events trigger Revision (see `trajectory-learning.md`)
- **Output:** Evaluation scores feed into agent reliability tracking
- **Output:** Persistent low scores trigger accelerated learning (more frequent reflection)

## Implementation

Script: `scripts/eval.sh`
Layer 1: Zero-cost heuristic (8 checks)
Layer 2: LLM via bridge (gray zone only)
