# Quick Start Guide

Get started with the Agent Evolution Kit in 15 minutes. Choose the track
that matches your setup.

## Prerequisites

- Git
- Any LLM API access (Claude, GPT, etc.)
- A text editor
- No special dependencies or frameworks required

## Track 1: Claude Code Users

The fastest path. The kit is designed to work natively with Claude Code.

### Step 1: Clone the Repository

```bash
git clone https://github.com/your-org/agent-evolution-kit.git
cd agent-evolution-kit
```

### Step 2: Copy Skills to Your Project

```bash
cp -r skills/ /path/to/your/project/skills/
```

Each skill is a self-contained markdown file with instructions, examples,
and integration points.

### Step 3: Set Up CLAUDE.md

Copy the orchestrator template to your project root:

```bash
cp templates/claude-md.md /path/to/your/project/CLAUDE.md
```

Edit the file to match your project. Key sections:
- **Role and communication rules**
- **Autonomous behavior boundaries** (what to do vs. ask permission)
- **Quality and security rules**
- **Workflow steps**

See [architecture.md](architecture.md) for details on the CLAUDE.md structure.

### Step 4: Configure Agent Profiles

If using multiple agents, create an AGENTS.md file:

```bash
cp templates/agent-profile.md /path/to/your/project/AGENTS.md
```

Define each agent's:
- Identity and role
- Capabilities
- Tools and permissions
- Behavioral constraints

### Step 5: Start Using Skills

Skills are invoked as slash commands in Claude Code conversations.
Start with these essential skills:

- `/reflexion` -- Post-failure self-evaluation
- `/weekly-evolution` -- Weekly improvement cycle
- `/security-review` -- Security checklist for changes

### Step 6: Set Up Weekly Evolution

Create the memory directory structure:

```bash
mkdir -p memory/reflections
mkdir -p memory/trajectory-pool
mkdir -p memory/knowledge
```

Schedule a weekly review (manual or cron-based) to:
1. Review failed tasks and their reflections
2. Extract patterns from the trajectory pool
3. Update agent prompts based on learnings

---

## Track 2: Other Framework Users

Adapting the kit to frameworks like LangChain, CrewAI, AutoGen, etc.

### Step 1: Understand the Concepts

Read these documents in order:
1. [architecture.md](architecture.md) -- System overview
2. [reflexion-protocol.md](reflexion-protocol.md) -- Learning from failures
3. [self-evolution-playbook.md](self-evolution-playbook.md) -- Evolution cycle

### Step 2: Adapt Skills to Your Framework

Skills in this kit are markdown-based instructions. To use them in other
frameworks:
- Extract the logic and criteria from each skill file.
- Implement them as your framework's native constructs (tools, chains,
  agents, etc.).
- Preserve the evaluation criteria and scoring rubrics.

### Step 3: Implement Reflexion (Start Here)

This is the highest-value, lowest-effort component:
1. After each failed task, generate a structured reflection.
2. Store reflections in a JSON or markdown file.
3. Inject the 3 most recent relevant reflections into agent prompts.

See [reflexion-protocol.md](reflexion-protocol.md) for the full protocol.

### Step 4: Add Trajectory Logging

Log every task with:
```json
{
  "task_id": "unique-id",
  "task_type": "web_research",
  "agent": "researcher-agent",
  "success": true,
  "duration_seconds": 15,
  "timestamp": "2026-01-15T10:00:00Z",
  "notes": "optional context"
}
```

### Step 5: Set Up Weekly Review

Even without automation, a manual weekly review is valuable:
1. Review failed tasks from the past week.
2. Identify recurring failure patterns.
3. Update agent instructions to address patterns.
4. Track changes in an evolution log.

### Step 6: Gradually Add More

Once reflexion and trajectory logging are stable, add:
- [Maker-checker loops](maker-checker.md) for quality-critical outputs
- [Circuit breakers](circuit-breaker.md) for fault tolerance
- [Capability routing](capability-routing.md) for multi-agent systems
- [Cross-agent critique](cross-agent-critique.md) for diverse perspectives

---

## Track 3: Evolution System Only

Use just the learning and improvement components, without the full agent
infrastructure.

### Step 1: Start with Reflexion

After each failed task, write a reflection:

```markdown
## Reflection: [Task Name]
- **What happened**: [describe the failure]
- **Root cause**: [why it failed]
- **What to do differently**: [specific actionable change]
- **Rule to add**: [new rule for agent prompt, if applicable]
```

### Step 2: Create the Reflection Directory

```bash
mkdir -p memory/reflections/
```

Store one reflection per file, named by date and task:
`memory/reflections/2026-01-15-web-search-failure.md`

### Step 3: Inject Reflections into Prompts

Before each task, include the 3 most recent reflections relevant to the
task type in the agent's context. This is the core learning mechanism.

### Step 4: Weekly Pattern Review

Every week:
1. Read through all reflections from the past week.
2. Look for patterns (same failure mode appearing 2+ times).
3. For each pattern, create a permanent rule in the agent prompt.
4. Archive processed reflections.

### Step 5: Add Trajectory Pool When Ready

Once reflexion is working, start logging all tasks (not just failures)
to build a trajectory pool. This enables:
- Success rate tracking per task type
- Performance trend detection
- Data-driven prompt evolution

---

## Minimal Viable Evolution

The simplest useful setup requires just three things:

1. **Reflexion after failures**: Write a structured reflection for each
   failed task.
2. **3 most recent reflections in context**: Include them in the agent's
   prompt before each task.
3. **Weekly review of patterns**: Manually review reflections and extract
   permanent rules.

This alone will measurably improve agent performance. Everything else in
the kit builds on top of this foundation.

## What to Read Next

- [architecture.md](architecture.md) -- Full system architecture
- [reflexion-protocol.md](reflexion-protocol.md) -- Detailed reflexion protocol
- [self-evolution-playbook.md](self-evolution-playbook.md) -- Complete evolution cycle
- [autonomy-layers.md](autonomy-layers.md) -- Progressive autonomy model
