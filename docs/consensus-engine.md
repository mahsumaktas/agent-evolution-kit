# Consensus Engine

Multi-agent voting system for collective decision-making. When multiple agents evaluate
the same question, the consensus engine aggregates their votes into a single decision
using one of five voting strategies.

## Overview

Individual agents have blind spots. A researcher might overvalue novelty, a security
agent might be overly conservative, and a finance agent might focus on cost above all
else. The consensus engine forces multiple perspectives into a structured vote, producing
decisions that are more robust than any single agent's judgment.

## Voting Types

### 1. Majority

Simple majority wins. More than 50% of votes must agree.

```bash
echo '[{"agent":"analyst","vote":"approve"},{"agent":"researcher","vote":"approve"},{"agent":"security","vote":"reject"}]' \
  | python3 scripts/helpers/consensus.py --type majority
# Output: {"decision": "approve", "votes_for": 2, "votes_against": 1, "quorum_met": true}
```

**When to use:** Routine decisions where a simple majority is sufficient.
Binary decisions (approve/reject, deploy/hold).

### 2. Supermajority

Requires two-thirds (66.7%) agreement. Stricter than majority, used for
higher-stakes decisions.

```bash
echo '[{"agent":"a","vote":"approve"},{"agent":"b","vote":"approve"},{"agent":"c","vote":"reject"},{"agent":"d","vote":"approve"}]' \
  | python3 scripts/helpers/consensus.py --type supermajority
# Output: {"decision": "approve", "votes_for": 3, "total": 4, "threshold": "66.7%", "quorum_met": true}
```

**When to use:** Production deployments, security policy changes, any decision
where a narrow majority is insufficient confidence.

### 3. Unanimous

All agents must agree. A single dissent blocks the decision.

```bash
echo '[{"agent":"a","vote":"approve"},{"agent":"b","vote":"approve"},{"agent":"c","vote":"approve"}]' \
  | python3 scripts/helpers/consensus.py --type unanimous
# Output: {"decision": "approve", "unanimous": true, "quorum_met": true}
```

**When to use:** Safety-critical decisions, irreversible actions, changes to
governance rules. If any agent has concerns, the action should not proceed.

### 4. Weighted

Agents have different vote weights based on domain expertise. A security agent's
vote carries more weight on security decisions than a content agent's vote.

```bash
echo '[{"agent":"security","vote":"reject","weight":3},{"agent":"analyst","vote":"approve","weight":1},{"agent":"researcher","vote":"approve","weight":1}]' \
  | python3 scripts/helpers/consensus.py --type weighted
# Output: {"decision": "reject", "weighted_for": 2, "weighted_against": 3, "quorum_met": true}
```

**When to use:** Domain-specific decisions where some agents have more relevant
expertise. The weight reflects domain authority, not general capability.

### 5. Quorum

A minimum number of agents must participate for the vote to be valid, regardless
of the outcome. Combines with any other voting type.

```bash
echo '[{"agent":"a","vote":"approve"},{"agent":"b","vote":"approve"}]' \
  | python3 scripts/helpers/consensus.py --type majority --quorum 3
# Output: {"decision": null, "error": "quorum_not_met", "required": 3, "present": 2}
```

**When to use:** Any vote where a minimum number of perspectives is required
for a valid decision. Prevents decisions made with insufficient input.

## Input Format

The engine accepts JSON via stdin. Each vote is an object with:

| Field | Required | Description |
|-------|----------|-------------|
| `agent` | Yes | Agent name (for audit trail) |
| `vote` | Yes | The agent's decision (string) |
| `weight` | No | Vote weight for weighted voting (default: 1) |
| `confidence` | No | Agent's confidence in its vote (0.0-1.0, informational) |
| `reasoning` | No | Agent's rationale (logged but not used in calculation) |

## Output Format

```json
{
  "decision": "approve",
  "votes_for": 3,
  "votes_against": 1,
  "total_votes": 4,
  "quorum_met": true,
  "voting_type": "majority",
  "timestamp": "2026-02-28T14:30:00Z"
}
```

When no decision can be reached (tie or quorum failure), `decision` is `null`
and an `error` field explains why.

## Early Termination

The engine supports early termination to save time in large agent groups:

- **Majority/Supermajority:** If enough votes are already in to guarantee the
  outcome, remaining agents are not polled.
- **Unanimous:** If any agent votes against, the vote terminates immediately.
- **Quorum failure:** If not enough agents are available, the vote fails without
  waiting for the timeout.

## Tie-Breaking

When votes are evenly split (possible with even numbers of agents):

1. **Default:** Escalate to the orchestrator for a tiebreaker decision.
2. **Conservative mode:** Ties default to the safer option (reject/hold).
3. **Custom:** Configurable per pattern via `on_tie` in the swarm YAML.

## Integration

### With Swarm Patterns

The consensus engine is the default aggregation method for the `consensus` swarm
pattern. Other patterns can invoke it for specific decision points.

```yaml
# In a swarm pattern config
aggregation: vote
voting: supermajority
on_tie: conservative
```

### With Cross-Agent Critique

After a MAR critique round, the critique scores can be fed into the consensus
engine to produce a collective quality judgment:

```bash
# Convert critique scores to votes
echo "$CRITIQUE_RESULTS" | python3 scripts/helpers/consensus.py --type weighted
```

### With Circuit Breaker

When a circuit breaker is in HALF-OPEN state and a probe succeeds, the consensus
engine can require multiple agents to confirm recovery before fully closing the circuit.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--type` | majority | Voting strategy |
| `--quorum` | 0 | Minimum votes required (0 = no minimum) |
| `--tie` | escalate | Tie-breaking strategy (escalate, conservative, random) |
| `--timeout` | 60 | Seconds to wait for all votes |
