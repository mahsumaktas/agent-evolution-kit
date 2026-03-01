# Autonomy Layers

A 5-layer model for progressively increasing agent autonomy. Each layer builds
on the previous one. Systems should be stable at one layer before advancing
to the next.

## Layer 1: Reactive (Always On)

- Agents respond **only** to direct human commands.
- No autonomous decision-making whatsoever.
- Human triggers every action explicitly.
- This is the baseline: every agent system starts here.

**Example**: User asks "summarize this document" and the agent summarizes it.
Nothing happens without a human prompt.

## Layer 2: Scheduled (Cron-Based)

- Agents run on predefined schedules (hourly, daily, weekly).
- Tasks are fixed and predetermined -- no variation or adaptation.
- Human defines the schedule and task list in advance.

**Examples**:
- Daily system health check at 03:00
- Weekly metrics report every Sunday at 22:00
- Nightly log rotation and cleanup

**Key constraint**: The agent executes the same predefined task every time.
It does not decide what to do or when.

## Layer 3: Self-Monitoring

- The system watches itself and **recovers from known failure patterns**.
- Automatic recovery actions for anticipated issues.
- Circuit breakers prevent cascading failures
  (see [circuit-breaker.md](circuit-breaker.md)).
- Self-healing: restart crashed services, retry failed operations,
  alert operators when recovery fails.

**Scripts at this layer**:
- `watchdog.sh` -- monitors service health, restarts crashed processes
- `system-check.sh` -- validates system state (disk, memory, connectivity)
- Circuit breaker state tracking per tool/API

**Key constraint**: The system can heal itself but cannot improve itself.
Recovery actions are predefined, not learned.

## Layer 4: Self-Improving

- Agents **learn from failures** and adapt over time.
- Weekly evolution cycle reviews performance and adjusts behavior.
- Reflexion protocol generates insights from failed tasks
  (see [reflexion-protocol.md](reflexion-protocol.md)).
- Prompt evolution: agent prompts are refined based on observed patterns
  (see [prompt-evolution.md](prompt-evolution.md)).
- Trajectory pool captures task history for pattern recognition.
- **Operator approval required** for all changes to production behavior.

**Scripts at this layer**:
- `weekly-cycle.sh` -- orchestrates the weekly evolution process
- `predict.sh` -- forecasts potential issues based on trajectory data
- `research.sh` -- investigates topics based on detected knowledge gaps

**Key constraint**: The system proposes improvements but a human approves
them before they take effect in production.

## Layer 5: Fully Autonomous (Future)

- ML-based routing replaces rule-based capability matching.
- Gradient-based prompt optimization (automated A/B testing of prompts).
- Runtime tool synthesis (agent creates new tools as needed).
- Autonomous cross-agent task delegation without orchestrator mediation.

**Prerequisite**: Stable Layer 4 operation for 3+ months with documented
improvement trajectory.

**Key constraint**: Even at Layer 5, safety rules (Layer 0) remain
human-controlled and cannot be autonomously modified.

## Current State

Most production agent systems operate at **Layer 3-4**. Layer 5 is aspirational
and requires significant advances in safe autonomous optimization.

A practical progression timeline:
- **Week 1-2**: Layer 1-2 (reactive + scheduled tasks)
- **Month 1-2**: Layer 3 (self-monitoring, circuit breakers, watchdog)
- **Month 3-6**: Layer 4 (reflexion, prompt evolution, trajectory learning)
- **Month 6+**: Evaluate readiness for Layer 5 components

## Safety Constraints per Layer

| Layer | Autonomous Actions | Requires Human Approval |
|---|---|---|
| 1 | None | Everything |
| 2 | Run scheduled tasks | Schedule changes, new tasks |
| 3 | Self-healing, monitoring, alerts | Config changes, new recovery rules |
| 4 | Prompt evolution, research, predictions | Production changes, new capabilities |
| 5 | Routing optimization, tool synthesis | Safety rule changes, constraint modifications |

## Design Principles

1. **Never skip layers**. A system that cannot reliably self-monitor (Layer 3)
   is not ready for self-improvement (Layer 4).

2. **Stability before advancement**. Spend at least 2-4 weeks at each layer
   before moving up. Track metrics to confirm stability.

3. **Approval gates increase with autonomy**. Higher layers have more
   autonomous actions but the remaining approval gates are more critical.

4. **Rollback is always possible**. Any layer advancement can be reversed by
   disabling the higher-layer scripts and reverting to the previous layer's
   behavior.

5. **Layer 0 is implicit**: Safety constraints (no force push, no secret
   exposure, no unauthorized destructive actions) apply at ALL layers and
   are never autonomously modifiable.
