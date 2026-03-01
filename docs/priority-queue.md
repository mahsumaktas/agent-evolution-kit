# Priority Queue

Task prioritization system with 5 levels, keyword-based auto-assignment, and drop
policies to prevent queue overflow. Ensures high-priority tasks are always processed
before lower-priority ones, and that the queue stays manageable under load.

## Priority Levels

| Level | Name | Description | Example |
|-------|------|-------------|---------|
| P0 | Critical | System down, data loss risk, security breach | Circuit breaker cascade, credential exposure |
| P1 | Urgent | Significant degradation, time-sensitive deadline | API failures affecting users, SLA breach risk |
| P2 | High | Important but not time-critical | Weekly evolution cycle, scheduled reports |
| P3 | Normal | Routine tasks with no urgency | Research tasks, content drafts, analytics |
| P4 | Low | Nice-to-have, background tasks | Documentation updates, cleanup, optimization |

### Priority Rules

- P0 and P1 tasks preempt all other work. If an agent is working on P3 and a P0
  arrives, the P3 task is paused and the P0 is processed immediately.
- P2 tasks are processed in FIFO order within their priority level.
- P3 and P4 tasks are processed only when no higher-priority tasks are pending.
- Tasks at the same priority level are processed in order of arrival (FIFO).

## Auto-Assignment

Tasks are automatically assigned a priority level based on keyword matching in the
task description. This provides a reasonable default that can be overridden manually.

### Keyword Table

| Priority | Keywords |
|----------|----------|
| P0 | crash, down, breach, data loss, security incident, critical failure |
| P1 | urgent, deadline, SLA, degraded, failing, timeout, blocked |
| P2 | important, scheduled, weekly, evolution, report |
| P3 | research, analyze, draft, review, summarize |
| P4 | cleanup, optimize, refactor, document, nice-to-have |

### Assignment Logic

1. Scan the task description for keywords (case-insensitive).
2. If keywords from multiple levels match, use the **highest** priority (lowest number).
3. If no keywords match, default to **P3** (Normal).
4. Manual override is always possible via `--priority P1` flag.

```bash
# Auto-assigned based on keywords
scripts/goal-decompose.sh add "Research trending AI topics for weekly report"
# -> Auto-assigned P3 (keyword: "research")

# Manual override
scripts/goal-decompose.sh add "Research trending AI topics" --priority P1
# -> Forced to P1 regardless of keywords
```

## Queue Drop Policy

To prevent unbounded queue growth, drop policies remove low-priority tasks when the
queue exceeds capacity limits.

| Priority | Max Queue Size | Drop Behavior |
|----------|---------------|---------------|
| P0 | Unlimited | Never dropped |
| P1 | Unlimited | Never dropped |
| P2 | 50 | Oldest dropped when limit reached |
| P3 | 30 | Oldest dropped when limit reached |
| P4 | 20 | Oldest dropped when limit reached |

### Drop Rules

1. When a new task is enqueued and the queue for its priority level is full, the
   **oldest** task at that priority level is dropped.
2. Dropped tasks are logged with reason `queue_overflow` and moved to an archive.
3. P0 and P1 tasks are **never** dropped regardless of queue size.
4. Drop events are reported in the daily briefing so operators are aware of lost tasks.
5. If drops are frequent (more than 5 per day at any level), the system generates
   a warning suggesting either increased processing capacity or priority recalibration.

## Queue Status

```bash
# View current queue status
scripts/goal-decompose.sh status

# Output:
# Priority Queue Status
# ---------------------
# P0 (Critical):  0 tasks
# P1 (Urgent):    1 task
# P2 (High):      4 tasks
# P3 (Normal):   12 tasks
# P4 (Low):       8 tasks
# Total:         25 tasks
# Dropped today:  0
```

## Integration

### With Goal Decomposition

The priority queue is built into the goal decomposition system. When
`goal-decompose.sh` breaks a high-level goal into subtasks, each subtask
inherits the parent goal's priority unless explicitly overridden.

### With Bridge

The bridge script (`scripts/bridge.sh`) consults the priority queue before
processing tasks. It selects the highest-priority pending task and passes it
to the appropriate agent. If a P0 task arrives while a lower-priority task is
in progress, the bridge can interrupt and reassign.

### With Metrics

Queue depth, drop counts, and processing times per priority level are tracked
in the metrics database. Weekly reports include queue health metrics.

### With Briefing

The daily briefing includes:
- Current queue depth per priority level
- Tasks dropped in the last 24 hours
- Average wait time per priority level
- Any P0/P1 tasks that have been pending for more than 1 hour

## Configuration

```yaml
# config/priority-rules.example.yaml
priority_queue:
  default_priority: P3
  max_queue_size:
    P0: 0    # 0 = unlimited
    P1: 0
    P2: 50
    P3: 30
    P4: 20
  drop_warning_threshold: 5
  keywords:
    P0:
      - crash
      - down
      - breach
      - data loss
      - security incident
    P1:
      - urgent
      - deadline
      - SLA
      - degraded
    P2:
      - important
      - scheduled
      - weekly
    P3:
      - research
      - analyze
      - draft
    P4:
      - cleanup
      - optimize
      - refactor
```

## Implementation

Priority assignment is integrated into `scripts/bridge.sh`. Every bridge call
automatically determines a priority level based on the task prompt.

### Bridge Priority Assignment

The bridge script assigns priority in this order:

1. **Manual override:** `--priority P1` flag or `AEK_PRIORITY=P1` environment variable.
2. **Keyword matching:** Scans `config/priority-rules.yaml` for keyword matches in
   the prompt text. Highest matching priority wins.
3. **Default:** If no keywords match and no override is set, defaults to P2.

```bash
# Auto-assigned based on keywords in the prompt
scripts/bridge.sh "Research trending AI topics for weekly report"
# -> Auto-assigned P3 (keyword: "research")

# Manual override via flag
scripts/bridge.sh --priority P1 "Research trending AI topics"
# -> Forced to P1

# Manual override via environment
AEK_PRIORITY=P0 scripts/bridge.sh "System is crashing"
# -> Forced to P0
```

### Trajectory Enrichment

The assigned priority is stored in each trajectory pool entry under the `priority`
field. This enables post-hoc analysis of task distribution across priority levels
and helps the weekly evolution cycle identify patterns in high-priority failures.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AEK_PRIORITY` | Priority level override (P0-P4) | Auto-detected |
| `AEK_TASK_TYPE` | Task type for trajectory enrichment | `general` |
