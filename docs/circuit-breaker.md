# Circuit Breaker Pattern

Fault tolerance pattern for tool and API failures in multi-agent systems.
Prevents cascading failures by isolating broken dependencies and enabling
graceful degradation.

## State Machine

```
CLOSED (normal) ──[error]──> counter++
  |                            |
  | (counter < 3)              | (counter >= 3)
  | <── retry (backoff) ───────┘
  |                            |
  |                            v
  |                         OPEN (circuit open)
  |                            |
  |                            | (5 min cooldown)
  |                            v
  |                         HALF-OPEN (single probe)
  |                            |
  | <── success ───────────────┤
  |                            |── failure -> OPEN (again)
  |                                          + alert to orchestrator
```

### States

- **CLOSED**: Normal operation. Errors increment a counter. Requests pass through.
- **OPEN**: Tool/API is considered unavailable. All requests are immediately rejected
  or routed to an alternative. No calls are made to the failing service.
- **HALF-OPEN**: After the cooldown period, a single probe request is sent to test
  whether the service has recovered.

## Retry Strategy

1. **First failure**: Exponential backoff with jitter (1s, 2s, 4s base delays).
2. **3 consecutive failures** on the same tool: Transition to OPEN state.
3. **Circuit open**: Skip the tool entirely. Use an alternative tool or report
   insufficiency to the orchestrator.
4. **After 5 minutes**: Transition to HALF-OPEN. Send a single probe request.
5. **Probe succeeds**: Transition back to CLOSED, reset failure counter.
6. **Probe fails**: Transition back to OPEN, restart the cooldown timer,
   and alert the orchestrator.

## State Tracking

Each tool or API endpoint maintains its own circuit breaker state in a JSON file:

```json
{
  "web_search": {
    "state": "CLOSED",
    "failures": 0,
    "last_failure": null,
    "last_success": "2026-01-15T10:30:00Z",
    "total_trips": 0
  },
  "github_api": {
    "state": "HALF_OPEN",
    "failures": 3,
    "last_failure": "2026-01-15T10:25:00Z",
    "last_success": "2026-01-15T09:00:00Z",
    "total_trips": 2
  },
  "llm_bridge": {
    "state": "CLOSED",
    "failures": 1,
    "last_failure": "2026-01-14T22:00:00Z",
    "last_success": "2026-01-15T10:29:00Z",
    "total_trips": 0
  }
}
```

## Implementation Rules

1. **Per-tool isolation**: Each tool/API has its own independent breaker. A failing
   web search does not affect the GitHub API breaker.
2. **Threshold is configurable**: Default is 3 consecutive failures, but
   high-availability tools (e.g., primary LLM) may use a threshold of 5.
3. **Cooldown is configurable**: Default is 5 minutes. External APIs with known
   slow recovery (e.g., rate-limited services) may use 15 minutes.
4. **24-hour OPEN alert**: If a circuit remains OPEN for more than 24 hours,
   alert the operator. This likely indicates a permanent failure requiring
   manual intervention.
5. **Stats in weekly evolution**: Circuit breaker trip counts and durations are
   included in the weekly evolution report. Frequently tripping circuits
   indicate systemic issues that need architectural fixes, not just retries.
6. **Prefer alternatives when OPEN**: If a secondary tool can serve the same
   purpose, route to it automatically. Only report insufficiency if no
   alternative exists.

## Integration with Other Patterns

- **Capability Routing**: When a circuit opens, the routing system automatically
  tries the secondary or fallback agent for that capability
  (see [capability-routing.md](capability-routing.md)).
- **Trajectory Pool**: Circuit breaker trips are recorded as task metadata.
  Repeated trips for the same task type may trigger a reflexion cycle.
- **Maker-Checker**: If the checker agent's tool circuit opens, the loop pauses
  and flags the output for manual review rather than auto-approving.

## Example: Handling a Web Search Failure

```
1. Agent requests web_search("latest trends in AI")
2. web_search returns timeout error
3. Circuit breaker: failures=1, state=CLOSED, retry after 1s
4. Retry: web_search returns timeout error
5. Circuit breaker: failures=2, state=CLOSED, retry after 2s
6. Retry: web_search returns timeout error
7. Circuit breaker: failures=3, state=OPEN
8. Orchestrator notified: "web_search circuit OPEN"
9. Route to alternative: use cached results or skip web search
10. After 5 minutes: probe web_search with lightweight query
11. Probe succeeds: state=CLOSED, failures=0
```

## Configuration Defaults

| Parameter | Default | Description |
|---|---|---|
| `failure_threshold` | 3 | Consecutive failures before OPEN |
| `cooldown_seconds` | 300 | Seconds before HALF-OPEN probe |
| `backoff_base` | 1.0 | Base delay in seconds for exponential backoff |
| `backoff_max` | 30.0 | Maximum backoff delay in seconds |
| `alert_after_hours` | 24 | Hours in OPEN before operator alert |

## Implementation

Script: `scripts/circuit-breaker.sh`
State: `memory/circuit-breaker-state.json`
Integration: Bridge checks before every call.
