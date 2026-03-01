# Cross-Agent Critique Protocol

## 1. Purpose

Single agents develop blind spots over time -- a phenomenon called *cognitive
entrenchment*. An agent that always handles the same domain stops questioning its
own assumptions. Cross-agent critique addresses this by having a different agent
review the output before it is finalized.

Based on the Multi-Agent Review (MAR) pattern: the producer creates, a designated
reviewer critiques, and the producer revises.

## 2. Critique Matrix

Each agent has a designated reviewer with a specific review focus:

| Producer            | Reviewer           | Focus                              |
| ------------------- | ------------------ | ---------------------------------- |
| researcher-agent    | analyst-agent      | Research depth, source diversity    |
| social-media-agent  | content-agent      | Tone, engagement, accuracy         |
| finance-agent       | security-agent     | Risk assessment, assumptions       |
| content-agent       | social-media-agent | Social media fit, viral potential   |
| analyst-agent       | researcher-agent   | Completeness, missing areas        |
| monitor-agent       | security-agent     | Measurement accuracy               |

The matrix ensures domain cross-pollination: the reviewer always comes from a
different specialization than the producer.

## 3. Triggers

| Trigger Type | Condition                                      | Action         |
| ------------ | ---------------------------------------------- | -------------- |
| Automatic    | Top 3 highest-impact tasks each week           | Critique REQUIRED |
| Manual       | Orchestrator flags a task for review            | Critique REQUIRED |
| Never        | Routine, low-risk tasks (status checks, etc.)  | Exempt         |

Selection criteria for automatic triggers:
- Tasks with external-facing output (published content, sent messages)
- Tasks involving financial decisions or risk assessments
- Tasks where the agent expressed low confidence

## 4. Critique Format

```markdown
# Critique: [date] - [reviewer] reviews [producer] - [task summary]

## Assessment
APPROVE / ISSUE / REJECT

## Strengths
- [1-2 concrete items the producer did well]

## Issues
- [1-3 specific problems, if any. Each must be actionable.]

## Suggestions
- [Optional improvements, not blocking approval]
```

Assessment definitions:
- **APPROVE**: Output is good. Ship it.
- **ISSUE**: Output has problems that need fixing before use.
- **REJECT**: Output is fundamentally flawed. Redo the task.

## 5. Process

1. **Detection**: Orchestrator identifies a task eligible for critique (automatic
   selection or manual flag).
2. **Assignment**: Orchestrator looks up the critique matrix and assigns the
   designated reviewer.
3. **Review**: Reviewer receives the producer's output and the original task
   description. Reviewer writes critique in the format above.
4. **Decision**: If APPROVE, output is finalized. If ISSUE, producer revises and
   resubmits. If REJECT, producer redoes the task from scratch.
5. **Revision**: Producer addresses each issue point. No cherry-picking -- all
   issues must be addressed or explicitly rebutted.
6. **Final check**: Reviewer confirms the revision. Maximum 2 cycles total
   (original + one revision). If still not approved after 2 cycles, escalate to
   the orchestrator.
7. **Recording**: Critique is stored in `memory/critiques/YYYY-MM-DD-<task>.md`
   for future reference and pattern detection.

## 6. Constraints

- **No self-review**: The reviewer must not be the same agent that produced the
  output.
- **Concise feedback**: Maximum 100 tokens per critique section (strengths,
  issues, suggestions). Be specific, not verbose.
- **Limited cycles**: Maximum 2 critique rounds per task. After that, the
  orchestrator decides.
- **Routine exemption**: Routine operational tasks (health checks, scheduled
  reports, status pings) are exempt from critique.
- **Time budget**: Critique should not take longer than 20% of the original task
  duration. If the review would be more expensive than the task, skip it.
