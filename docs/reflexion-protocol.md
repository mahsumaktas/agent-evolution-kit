# Reflexion Protocol

## 1. Purpose

Agents learn from failures through verbal self-evaluation (Shinn et al., 2023).
No weight updates or fine-tuning needed -- just natural language reflection stored
in memory and injected into future prompts. When an agent fails, it writes down
*what went wrong* and *what to do differently*. Next time a similar task appears,
the reflection is included in the prompt so the mistake is not repeated.

## 2. When Triggered

| Outcome            | Reflection Type       | Fields | Required?   |
| ------------------ | --------------------- | ------ | ----------- |
| Task **FAILED**    | Full reflection       | 5      | MANDATORY   |
| Task **PARTIAL**   | Short reflection      | 3      | MANDATORY   |
| Task **SUCCESS**   | Procedure summary     | 2      | OPTIONAL    |
| Important decision | Decision reflection   | 3      | RECOMMENDED |

Rules:
- Failed and partial tasks MUST produce a reflection before the agent moves on.
- Success procedures are optional but recommended for non-trivial tasks.
- Decision reflections capture *why* a choice was made when multiple paths existed.

## 3. Reflection Format

### 3a. Failed Task (5 fields)

```markdown
# Reflection: [date] - [agent-name] - [task summary]
## What happened?
## What went wrong?
## Why did it go wrong?
## What should I do differently?
## Tactical rule candidate
```

- *What happened?* -- factual description of the task and outcome.
- *What went wrong?* -- the specific failure point (which step, tool, input).
- *Why did it go wrong?* -- root cause (wrong strategy, bad input, missing knowledge, external failure).
- *What should I do differently?* -- actionable correction, specific enough to follow.
- *Tactical rule candidate* -- one-sentence preventive rule. Example: "Always validate API response status before parsing the body."

### 3b. Partial Task (3 fields)

Same as above but only: *What happened?*, *What went wrong?*, *What should I do differently?*

### 3c. Success Procedure (2 fields)

```markdown
# Procedure: [date] - [agent-name] - [task summary]
## Strategy
## Why it worked
```

### 3d. Decision Reflection (3 fields)

*What was the decision?*, *What alternatives existed?*, *Why was this option chosen?*

## 4. Storage

Reflections are stored as markdown files:

```
memory/reflections/<agent-name>/YYYY-MM-DD-<short-title>.md
```

Naming: lowercase, hyphens, max 5 words.
Example: `memory/reflections/researcher-agent/2026-03-01-api-timeout-handling.md`

Retention: last 30 per agent. Archive older ones yearly.

## 5. Usage: In-Context Learning

When an agent starts a task, the orchestrator injects the **last 3 relevant
reflections** into the agent's system prompt.

Relevance criteria (in priority order):
1. **Same task type** (e.g., "web scraping" tasks get web scraping reflections)
2. **Same tool or API** (e.g., reflections mentioning a specific API endpoint)
3. **Recency** as tiebreaker

## 6. MARS Metacognitive Reflection

For important reflections (failed tasks and significant decisions), produce two
additional outputs following the MARS dual-reflection pattern:

- **Principle** (normative, preventive): "I should follow this rule: [one-sentence rule]"
  Feeds the Prompt Evolution tactical stream. Candidates for permanent system prompt rules.

- **Procedure** (descriptive, replicable): "These steps worked: [numbered step list]"
  Feeds the Record & Replay system. Becomes a reusable playbook.

Reserve MARS output for failures with systemic causes or successes with
replicable strategies -- not every reflection needs it.

## 7. Advanced: Vector DB Integration (Reflexion v2)

For mature deployments, store reflections with vector embeddings for semantic
retrieval instead of keyword/tag matching:

1. On creation, generate an embedding from the reflection content.
2. Store the embedding alongside the markdown file in a vector database.
3. At task start, embed the task description and retrieve the top 3 most
   semantically similar past reflections (regardless of agent).

Retry policy with reflection:
- On failure, generate reflection, then retry with the reflection in context.
- Maximum 3 retries. Each retry includes all previous reflections from the chain.
- If all 3 retries fail, escalate to the orchestrator.

## 8. Security

Reflections must NEVER contain:
- API keys, tokens, passwords, or secrets
- Personal or identifiable information
- Internal infrastructure details (IPs, hostnames, internal URLs)

If a failure involves a secret, describe it generically: "Authentication failed
due to expired credentials" -- never include the actual credential value.
