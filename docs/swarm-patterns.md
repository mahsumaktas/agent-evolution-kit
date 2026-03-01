# Swarm Patterns

Multi-agent orchestration templates for coordinating groups of agents on complex tasks.
Each pattern defines a communication topology, decision flow, and failure handling strategy.

## Overview

Swarm patterns are reusable coordination blueprints. Instead of writing ad-hoc multi-agent
workflows, you select a pattern that matches your coordination need, configure it with
your agents and task, and run it through the swarm runner. The runner handles agent
communication, result aggregation, timeout enforcement, and failure recovery.

Currently 24 patterns are available: 8 fully implemented with YAML configs and runner
support, plus 16 documented patterns ready for implementation.

## Running a Swarm

```bash
# Basic usage
scripts/swarm.sh --pattern consensus --agents "analyst,researcher,security" --task "Evaluate deployment risk"

# With options
scripts/swarm.sh --pattern pipeline --agents "researcher,writer,reviewer" --task "Write report on X" --timeout 300

# Dry run (shows plan without executing)
scripts/swarm.sh --pattern fan-out --agents "a,b,c" --task "..." --dry-run
```

**Parameters:**
- `--pattern`: Pattern name (must match a YAML file in `config/swarm-patterns/`)
- `--agents`: Comma-separated list of agent names
- `--task`: Task description passed to agents
- `--timeout`: Maximum seconds for the entire swarm (default: 600)
- `--dry-run`: Show execution plan without running

## Implemented Patterns (8)

### 1. Consensus

All agents independently evaluate the same task. Results are aggregated through a voting
mechanism (see [consensus-engine.md](consensus-engine.md)).

```yaml
# config/swarm-patterns/consensus.yaml
pattern: consensus
min_agents: 3
voting: majority
timeout_per_agent: 120
aggregation: vote
on_tie: escalate
```

**Use case:** Risk assessment, go/no-go decisions, quality evaluation where multiple
perspectives reduce individual bias.

### 2. Pipeline

Agents execute sequentially. Each agent receives the previous agent's output as input.
The chain stops on failure unless `continue_on_error` is set.

```yaml
pattern: pipeline
min_agents: 2
timeout_per_agent: 180
pass_output: true
continue_on_error: false
```

**Use case:** Content creation (research -> draft -> review -> edit), data processing
pipelines, staged analysis.

### 3. Fan-Out

A single task is decomposed into subtasks, distributed to agents in parallel, and
results are merged when all complete.

```yaml
pattern: fan-out
min_agents: 2
timeout_per_agent: 120
merge_strategy: concatenate
wait_for_all: true
max_parallel: 5
```

**Use case:** Parallel research across multiple sources, bulk data processing,
independent analysis of different aspects of a problem.

### 4. Reflection

An agent produces output, then a different agent critiques it. The original agent
revises based on feedback. Configurable iteration depth.

```yaml
pattern: reflection
min_agents: 2
max_iterations: 3
score_threshold: 7
timeout_per_iteration: 180
```

**Use case:** Self-improvement loops, quality refinement, iterative problem solving
where critique improves output quality.

### 5. Review Loop

Similar to reflection but with a dedicated reviewer pool. Multiple reviewers score
the output independently. The maker revises only if the average score is below threshold.

```yaml
pattern: review-loop
min_agents: 3
roles:
  maker: 1
  reviewers: rest
max_iterations: 3
score_threshold: 7
```

**Use case:** Content review, code review simulation, any output that benefits from
independent quality scoring before acceptance.

### 6. Red Team

One group of agents (blue team) produces a solution. Another group (red team) attacks
it -- finding flaws, edge cases, and failure modes. The blue team then hardens the
solution based on red team findings.

```yaml
pattern: red-team
min_agents: 4
roles:
  blue_team: 2
  red_team: 2
rounds: 2
attack_categories:
  - edge_cases
  - security
  - reliability
```

**Use case:** Security review, stress testing proposals, adversarial evaluation
of plans or designs.

### 7. Escalation

Agents are arranged in tiers. A task starts at the lowest tier. If the agent cannot
handle it (confidence below threshold or explicit escalation), it moves up to the next
tier. Higher tiers use more capable (and more expensive) agents.

```yaml
pattern: escalation
tiers:
  - agents: [fast-agent]
    timeout: 30
    confidence_threshold: 0.7
  - agents: [standard-agent]
    timeout: 120
    confidence_threshold: 0.8
  - agents: [expert-agent]
    timeout: 300
    confidence_threshold: 0.0
```

**Use case:** Cost-efficient task handling where most tasks can be handled by cheap
agents, with expensive agents reserved for difficult cases.

### 8. Circuit Breaker

Wraps any other pattern with circuit breaker protection. If the inner pattern fails
repeatedly, the circuit opens and tasks are routed to a fallback.

```yaml
pattern: circuit-breaker
inner_pattern: pipeline
failure_threshold: 3
cooldown_seconds: 300
fallback: escalation
```

**Use case:** Production resilience. Combines with any other pattern as a wrapper.

## Documented Patterns (16)

These patterns are defined conceptually and can be implemented by creating
the corresponding YAML config file and extending the runner.

| Pattern | Description |
|---------|-------------|
| **Competitive** | Multiple agents race to solve the same task. First acceptable result wins. |
| **Debate** | Two agents argue opposing positions. A judge agent selects the stronger argument. |
| **Auction** | Agents bid on tasks based on their capability and current load. Lowest-cost capable agent wins. |
| **Hub-Spoke** | Central coordinator distributes subtasks to specialist agents and aggregates results. |
| **Mesh** | Agents communicate peer-to-peer without a central coordinator. Each agent can request help from any other. |
| **Handoff** | Agent works until it hits a capability boundary, then hands off to a more suitable agent with full context. |
| **Cascade** | Output flows through agents like a waterfall. Each agent adds its domain expertise to the growing result. |
| **DAG** | Directed acyclic graph of agent dependencies. Agents run as soon as their prerequisites complete. |
| **Hierarchical** | Tree structure where manager agents decompose tasks for worker agents below them. |
| **Map-Reduce** | Distribute data chunks to agents (map), then combine partial results (reduce). |
| **Scatter-Gather** | Broadcast a query to all agents, collect responses within a timeout, synthesize the best answer. |
| **Supervisor** | A dedicated supervisor agent monitors worker agents, reassigning tasks on failure. |
| **Saga** | Multi-step transaction with compensating actions. If step N fails, steps N-1 through 1 are rolled back. |
| **Blackboard** | Agents read from and write to a shared knowledge space. Each agent contributes what it can. |
| **Swarm** | Large number of simple agents coordinate through stigmergy (indirect communication via shared state). |
| **Verifier** | After any agent produces output, a verifier agent checks it against ground truth or constraints. |

## Creating Custom Patterns

Create a YAML file in `config/swarm-patterns/` with the pattern definition. Required
fields: `pattern`, `min_agents`, `timeout_per_agent`. Optional: `roles`,
`max_iterations`, `merge_strategy`, `on_failure`. The runner reads the YAML and
orchestrates agents accordingly.

Inspired by the AgentWorkforce relay architecture, adapted for shell-based
orchestration with YAML-driven configuration.
