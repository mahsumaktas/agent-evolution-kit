# Minimal Evolution Setup

The simplest useful implementation of the Agent Evolution Kit. Start here if you want to add self-improvement to an existing agent system without changing your entire architecture.

## What You Need

- Any LLM-powered agent (Claude, GPT, Gemini, open-source)
- A place to store text files (local filesystem is fine)
- 10 minutes to set up

## Setup

### Step 1: Create the memory structure

```bash
mkdir -p memory/reflections/my-agent
touch memory/trajectory-pool.json
echo "[]" > memory/trajectory-pool.json
```

### Step 2: Add reflexion to your agent workflow

After every failed task, generate a reflection:

```markdown
# Reflection: [date] - [agent] - [what was attempted]

## What happened?
[1-2 sentences: task and expected outcome]

## What went wrong?
[1-2 sentences: root cause]

## What should I do differently?
[1-2 sentences: specific, actionable change]

## Tactical rule candidate
IF [condition] THEN [action]
```

Save to `memory/reflections/my-agent/YYYY-MM-DD-<title>.md`

### Step 3: Inject reflections into your agent prompt

Before each task, append the last 3 relevant reflections to your agent's system prompt:

```markdown
## Past Lessons
1. [date]: [what went wrong] → [what to do differently]
2. [date]: [what went wrong] → [what to do differently]
3. [date]: [what went wrong] → [what to do differently]
```

"Relevant" = same task type or same tool/API.

### Step 4: Record task outcomes

After every task (success or failure), append to `memory/trajectory-pool.json`:

```json
{
  "id": "2026-03-01-my-agent-research",
  "agent": "my-agent",
  "task_type": "research",
  "strategy": "What approach was used",
  "result": "SUCCESS",
  "failure_reason": null,
  "tokens_used": 5000,
  "duration_s": 30,
  "key_actions": ["step 1", "step 2"],
  "lessons": "Optional one-line learning",
  "timestamp": "2026-03-01T10:00:00Z"
}
```

### Step 5: Weekly review (5 minutes)

Every week, manually review:

1. **What failed?** Read reflections from the past week
2. **Any patterns?** Same error type appearing multiple times?
3. **One change:** Add one tactical rule to your agent's prompt based on the most common failure

That's it. This alone will measurably improve your agent's performance over time.

## What's Next?

Once this is working:

1. **Add prompt evolution** — Formalize tactical (IF/THEN) and strategic rules. See [docs/prompt-evolution.md](../../docs/prompt-evolution.md)
2. **Add trajectory matching** — When a new task arrives, find similar past tasks and inject them as examples. See [docs/record-and-replay.md](../../docs/record-and-replay.md)
3. **Add cross-agent critique** — If you have multiple agents, have them review each other's output. See [docs/cross-agent-critique.md](../../docs/cross-agent-critique.md)
4. **Automate the weekly cycle** — Use [scripts/weekly-cycle.sh](../../scripts/weekly-cycle.sh) to automate the review process

## Why This Works

The core insight from the [Reflexion paper](https://arxiv.org/abs/2303.11366) is simple: agents that reflect on failures in natural language and inject those reflections into future prompts perform significantly better — without any weight updates or fine-tuning.

You're giving your agent a memory of its mistakes. That's the minimum viable evolution.
