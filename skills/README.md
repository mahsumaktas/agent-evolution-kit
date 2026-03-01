# Skills

Skills are structured markdown files (SKILL.md) that define rigid, repeatable workflows for AI agents. They are not suggestions or guidelines — they are enforced procedures with hard gates and red flags that prevent common failure modes.

## Design Principles

- **Hard gates**: Critical checkpoints that block progress until satisfied. An agent cannot skip a gate, even if the task seems simple.
- **Red flags**: Thought patterns that signal process violations. When an agent catches itself thinking a red-flag phrase, it must stop and restart from the correct phase.
- **Composability**: Skills reference other skills. A debugging skill calls the TDD skill when creating a regression test. A brainstorming skill hands off to the execution skill. This creates a dependency graph of workflows.
- **Framework-agnostic**: Skills are plain markdown. They work with any agent framework — adapt the tool references and spawn mechanisms to your platform.

## Included Skills

| Skill | Description |
|-------|-------------|
| [tdd-workflow](tdd-workflow/SKILL.md) | Test-Driven Development cycle. Write failing tests before implementation code. |
| [systematic-debugging](systematic-debugging/SKILL.md) | Four-phase root cause investigation. No fix without understanding the cause first. |
| [verification-gate](verification-gate/SKILL.md) | Evidence-based completion claims. No "done" without fresh verification output. |
| [structured-brainstorming](structured-brainstorming/SKILL.md) | Design-first workflow with hard gate blocking code until design is approved. |
| [subagent-execution](subagent-execution/SKILL.md) | Delegate implementation plans to subagents with two-stage review (spec + quality). |
| [orchestrator-loop](orchestrator-loop/SKILL.md) | Five-stage pipeline for orchestrator agents that delegate but never write code directly. |

## How to Use

1. **Copy the skills you need** into your agent's context or prompt library.
2. **Adapt tool references** to your platform (e.g., replace `[spawn subagent]` with your framework's spawn mechanism).
3. **Wire skill references** — when a skill says "REQUIRED SKILL: `tdd-workflow`", ensure that skill is also loaded.
4. **Respect the dependency graph**: `orchestrator-loop` calls `structured-brainstorming`, which calls `subagent-execution`, which uses `tdd-workflow`, `systematic-debugging`, and `verification-gate`.

## Creating Custom Skills

A skill file needs:

1. **YAML frontmatter** with `name` and `description` fields.
2. **Iron Rule** — the single non-negotiable constraint.
3. **Process phases** — ordered steps with clear entry/exit criteria.
4. **Red Flags** — thought patterns that indicate the agent is deviating.
5. **Rationalizations table** — common excuses paired with rebuttals.
6. **Integration section** — which other skills this skill depends on or feeds into.

Keep skills focused on one concern. A skill that tries to cover debugging AND testing AND deployment is three skills pretending to be one.
