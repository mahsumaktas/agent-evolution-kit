# Metacognitive Reflection

Dual reflection extraction from a single LLM call, based on the MARS framework (arXiv 2601.11974). Every important task produces two types of insight — a normative principle and a descriptive procedure — extracted together to minimize token cost.

## Overview

After an agent completes an important task (whether successfully or not), the system extracts two complementary reflections in a single LLM call. This dual extraction captures both the "what rule to follow" and the "what steps to take" dimensions of learning, feeding them into different downstream systems.

## Principle Reflection (Normative)

Answers the question: **"What rule should I follow to avoid this mistake or replicate this success?"**

**Characteristics:**
- Preventive and rule-based
- Expressed as a general guideline, not tied to specific steps
- Feeds into the Prompt Evolution tactical stream (see `prompt-evolution.md`)

**Examples:**
- After API failure: "API calls should always include a retry mechanism with exponential backoff. Never fail after a single attempt."
- After successful research: "Cross-referencing at least two independent sources catches errors that single-source research misses."
- After formatting rejection: "Financial data should always include the date of the data point. Undated financial figures are unreliable."

**Quality Criteria:**
- Must be specific enough to act on (no "be more careful")
- Must be general enough to apply beyond the single task
- Must state both the rule and the reasoning

## Procedure Reflection (Descriptive)

Answers the question: **"What exact steps led to this outcome?"**

**Characteristics:**
- Replicable and recipe-based
- Expressed as an ordered list of concrete actions
- Feeds into Record & Replay low-level storage (see `record-and-replay.md`)

**Examples:**
- After successful vulnerability scan:
  1. Query NVD API with product name and version
  2. Filter results by severity >= HIGH
  3. Cross-reference with GitHub Advisory Database
  4. Rank by CVSS score descending
  5. Generate summary with affected versions and patch availability

- After successful content creation:
  1. Scrape trending topics from platform API
  2. Filter to topics active in last 7 days
  3. Sort by growth rate
  4. Select top 5 with highest engagement potential
  5. Draft content matching platform format constraints

## Extraction Process

Both reflections are extracted in a single LLM call to avoid token waste:

```
Orchestrator sends to the evaluating model:

"Evaluate this completed task:

Task: [task description]
Agent: [agent name]
Result: [SUCCESS/FAILURE]
Output: [abbreviated output or error]
Duration: [seconds]

Extract two reflections:

1. PRINCIPLE: What general RULE should be followed based on this outcome?
   (1-2 sentences. Must be specific and actionable.)

2. PROCEDURE: What exact STEPS were taken (or should have been taken)?
   (Bulleted list. Each step must be a concrete action.)
"
```

The response is parsed and routed:
- Principle reflection goes to Prompt Evolution (tactical rule candidate)
- Procedure reflection goes to Record & Replay (low-level trajectory)

## When to Reflect

Not every task warrants reflection. Reflection is triggered when any of these conditions are met:

| Condition | Rationale |
|-----------|-----------|
| Task failed | Failures are the highest-value learning opportunities |
| Task importance is HIGH | Important tasks justify the reflection cost |
| Task duration exceeded 60 seconds | Long tasks indicate complexity worth recording |
| Agent has had 2+ recent failures | Agents in a failure pattern need accelerated learning |

**Skip reflection for:**
- Trivial tasks (status checks, simple lookups, single-step operations)
- Tasks that completed in under 5 seconds with expected output
- Repeated tasks where an identical trajectory already exists

## Cost Control

- Single LLM call for both reflections (never two separate calls)
- Use the cheapest available model for reflection extraction (evaluation does not require the most capable model)
- Reflection prompt is kept under 500 tokens including task context
- Skip reflection for trivial tasks to avoid unnecessary spend

## Routing

```
Reflection extracted
  |
  ├── Principle --> Prompt Evolution (tactical stream)
  |                   IF rule persists 4+ weeks --> Strategic stream
  |
  └── Procedure --> Record & Replay (low-level storage)
                      Matched by task_type for future in-context examples
```

## Integration Points

- **Input:** Completed task results (success or failure)
- **Output:** Principle reflections feed Prompt Evolution tactical stream
- **Output:** Procedure reflections feed Record & Replay low-level storage
- **Trigger:** Orchestrator initiates reflection after qualifying tasks

## Implementation

Trigger: Auto post-failure in `scripts/bridge.sh`
Principles: `memory/principles/{agent}.md`
Cost: 2 haiku calls per reflection
