# Maker-Checker Pattern

Dual-agent verification loop for quality-critical outputs. One agent produces,
a different agent evaluates. This eliminates blind spots that occur when an
agent reviews its own work.

## Flow

```
Maker Agent                    Checker Agent
    |                               |
    |── produce output ──>          |
    |                          evaluate against criteria
    |                               |
    |          <── score + feedback ─|
    |                               |
    | score >= threshold?           |
    |   YES -> accept output        |
    |   NO  -> revise with feedback |
    |          (max 3 iterations)   |
    |                               |
    | 3 iterations, none pass?      |
    |   -> select best version      |
    |   -> flag "review needed"     |
```

### Step-by-Step

1. **Maker agent** produces an output (content, analysis, report, etc.).
2. **Checker agent** (a DIFFERENT agent) evaluates the output against
   predefined quality criteria.
3. If the **score is below threshold**, the checker returns the output to the
   maker with **specific, actionable feedback**.
4. The maker revises and resubmits. **Maximum 3 iterations**.
5. If no version passes after 3 iterations, the system selects the
   **highest-scoring version** and marks it with a `"review_needed": true` flag
   for human review.

## Default Agent Pairings

| Maker | Checker | Domain |
|---|---|---|
| content-agent | analyst-agent | Content quality, factual consistency |
| researcher-agent | security-agent | Security-sensitive research findings |
| social-media-agent | content-agent | Social content, tone, brand alignment |
| finance-agent | security-agent | Financial reports, risk assessment |
| Any agent | orchestrator | Strategic decisions, high-impact outputs |

### Why These Pairings?

- The checker should have **domain expertise** relevant to the output type.
- The checker should have a **different perspective** than the maker
  (e.g., security-agent checks for risks that researcher-agent might overlook).
- The orchestrator serves as the universal fallback checker for high-stakes
  decisions.

## Scoring Thresholds

| Domain | Method | Threshold |
|---|---|---|
| Content quality | Numeric score (1-10) | >= 7 |
| Security review | Binary | approve / reject |
| Strategic decisions | Numeric score (1-10) | >= 8 |
| Financial analysis | Numeric score (1-10) | >= 7 |
| Social media content | Numeric score (1-10) | >= 7 |

## Rules

### Feedback Quality

- Checker feedback MUST be **specific and actionable**.
- Generic feedback like "improve it" or "not good enough" is **forbidden**.
- Good feedback example: "The risk assessment section lacks quantitative data.
  Add at least 2 data points supporting the risk level classification."
- Bad feedback example: "The report needs more detail."

### Separation of Concerns

- The checker agent must be **different** from the maker agent. Self-review
  creates blind spots where the same reasoning errors go undetected.
- If the designated checker is unavailable (circuit breaker OPEN), escalate to
  the orchestrator rather than allowing self-review.

### Iteration Limits

- **Maximum 3 iterations** per maker-checker loop. This prevents infinite
  revision cycles that waste tokens and time.
- After 3 iterations without passing, the system selects the version with the
  **highest checker score** and flags it for human review.
- The entire loop (all iterations) is recorded in the trajectory pool for
  future analysis.

### Cost Awareness

- Each iteration costs tokens. For low-stakes outputs, consider skipping the
  maker-checker loop entirely.
- The orchestrator decides whether a task warrants maker-checker verification
  based on task priority and domain.

## Integration with Other Patterns

- **Trajectory Pool**: Every maker-checker loop is recorded with iteration count,
  scores, and final outcome. High iteration counts for a specific task type
  may trigger a reflexion cycle.
- **Circuit Breaker**: If the checker agent's tools fail during evaluation, the
  circuit breaker pattern applies. The output is flagged for manual review
  rather than auto-approved.
- **Capability Routing**: The routing system uses maker-checker success rates
  to refine agent pairings over time.

## Example: Content Review Loop

```
Iteration 1:
  Maker (content-agent): Produces blog post draft
  Checker (analyst-agent): Score 5/10
    Feedback: "Missing source citations in paragraphs 2 and 4.
              Conclusion contradicts the data presented in section 3."

Iteration 2:
  Maker (content-agent): Revises with citations, fixes conclusion
  Checker (analyst-agent): Score 7/10
    Result: PASS (threshold met)

Output accepted. Trajectory recorded: 2 iterations, final score 7.
```
