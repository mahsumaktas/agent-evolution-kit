# Cognitive Memory

Advanced memory system that combines spaced repetition decay modeling, multi-channel importance scoring, prediction error gating, and adaptive pruning. This system determines what agents remember, how long they remember it, and when old memories should be updated or retired.

## Overview

Agent memory is not a simple key-value store. Information has varying importance, decays at different rates, and sometimes contradicts previously stored knowledge. Cognitive Memory models these dynamics using four interconnected mechanisms: FSRS-6 decay modeling, 4-channel importance scoring, prediction error gating for write control, and BCM-inspired pruning for size management.

## FSRS-6 Spaced Repetition

Models memory retention over time using a power-law decay function, based on the Free Spaced Repetition Scheduler version 6.

**Retention Formula:**

```
R = (1 + t / (9 * S))^(-1/0.5)
```

Where:
- `R` = retention probability (0.0 to 1.0)
- `t` = time elapsed since last access (in days)
- `S` = stability (how resistant the memory is to decay)

**Why Power-Law Over Exponential:**

Exponential decay (`R = e^(-t/S)`) drops too aggressively for long-term memories. Power-law decay has a heavier tail, meaning well-established memories retain meaningful probability even after long periods without access. This better matches how real-world information remains useful — a fact accessed 10 times over 6 months should not decay to near-zero after 30 days of inactivity.

**Stability Growth:**

Stability (S) increases each time a memory is successfully recalled (accessed and found useful):

```
S_new = S_old * (1 + growth_factor)
```

The growth factor depends on the difficulty of the recall and the current retention at the time of access. Easy recalls (high R at access time) produce smaller stability gains. Hard recalls (low R at access time) produce larger gains — the spacing effect.

**Practical Implications:**
- Frequently accessed memories become very stable (high S) and resist decay
- Rarely accessed memories decay and become pruning candidates
- A single access after a long gap produces a larger stability boost than frequent recent accesses

## 4-Channel Importance Scoring

Every memory receives an importance score computed from four independent channels:

| Channel | Weight | Description |
|---------|--------|-------------|
| Novelty | 0.25 | How new or surprising is this information compared to existing memories? |
| Arousal | 0.30 | How urgent or critical is this information? (security alerts, errors, deadlines) |
| Reward | 0.25 | How useful has similar information been in past tasks? |
| Attention | 0.20 | How relevant is this information to the current active context? |

**Composite Score:**

```
importance = (novelty * 0.25) + (arousal * 0.30) + (reward * 0.25) + (attention * 0.20)
```

Each channel produces a score between 0.0 and 1.0. The composite importance score is also 0.0 to 1.0.

**Channel Details:**

- **Novelty:** Computed by comparing the new information against existing memories. High similarity to existing memories = low novelty. Completely new information = high novelty. Measured via text similarity (Jaccard or cosine, depending on available infrastructure).

- **Arousal:** Heuristic-based. Presence of keywords like "critical", "security", "error", "deadline", "urgent" increases arousal. Financial figures, CVE identifiers, and error codes also boost arousal. Baseline arousal for routine information is 0.2.

- **Reward:** Historical utility tracking. If similar memories (by category or topic) have been accessed frequently in past tasks, the reward channel scores higher. Memories in categories that are never accessed score low.

- **Attention:** Contextual relevance. Scored higher when the information relates to currently active tasks or recently discussed topics. Decays when context shifts.

**Usage:** Importance scores influence retention decisions, pruning priority, and retrieval ranking. High-importance memories are retained longer and surface first in recall queries.

## Prediction Error (PE) Gating

Controls the write path: what happens when new information arrives that may overlap with existing memories.

**Concept:** Prediction error measures how much the new information differs from what the system already knows. Low PE means "this is already known." High PE means "this is truly new."

**PE Calculation:**
Compare incoming information against the most similar existing memory using text similarity (Jaccard similarity for text, cosine similarity if vector embeddings are available).

```
PE = 1.0 - similarity_to_closest_existing_memory
```

**Gating Actions:**

| PE Score | Action | Rationale |
|----------|--------|-----------|
| < 0.70 | CREATE | Information is sufficiently novel. Store as a new memory. |
| 0.70 - 0.74 | (gap zone) | Ambiguous. Default to CREATE if importance is high, otherwise skip. |
| 0.75 - 0.92 | UPDATE | Information overlaps with existing memory but adds new detail. Merge into the existing record. |
| > 0.92 | REINFORCE | Information is nearly identical to existing memory. No write needed. Boost stability of existing memory instead. |
| Contradiction | SUPERSEDE | New information directly contradicts existing memory. Mark old memory as invalid, create new memory with `supersedes` link. |

**Contradiction Detection:**
A contradiction is flagged when the similarity is high (PE < 0.30) but key values differ — for example, same entity but different version number, same metric but different value, or same configuration but different setting.

## BCM Pruning (Bienenstock-Cooper-Munro)

Adaptive pruning mechanism that prevents unbounded memory growth by using a floating threshold based on actual usage patterns.

**Threshold Calculation:**

```
threshold = average(access_count across all memories)
```

The threshold is recalculated periodically (daily or weekly). Memories with access counts below the threshold are candidates for pruning.

**Category-Based Minimum Retention:**

Not all memories should be pruned on the same schedule. Some categories have enforced minimum retention periods regardless of access count:

| Category | Minimum Retention |
|----------|-------------------|
| Corrections | 9999 days (effectively permanent) |
| Preferences | 9999 days (effectively permanent) |
| Entities | 9999 days (effectively permanent) |
| Decisions | 45 days |
| Facts | 14 days |
| Other | 7 days |

**Pruning Process:**
1. Calculate current threshold from average access count
2. Identify memories below threshold
3. Check minimum retention period for each candidate's category
4. If minimum retention has not elapsed, skip (do not prune)
5. If minimum retention has elapsed and access count is below threshold, mark for pruning
6. Pruned memories are not deleted — they are archived (moved to cold storage)

**Why BCM Over Fixed Threshold:**
A fixed threshold (e.g., "prune if accessed fewer than 3 times") becomes wrong as the system scales. With 50 memories, 3 accesses might be average. With 5000 memories, 3 accesses might be well above average. BCM's floating threshold adapts to the actual distribution.

## Bi-Temporal Memory Model

Every memory carries two temporal dimensions:

| Field | Description |
|-------|-------------|
| `valid_from` | When the information became true in the real world |
| `invalid_at` | When the information stopped being true (null if still valid) |
| `recorded_at` | When the system stored this memory |
| `supersedes` | Link to the older memory this one replaces (null if original) |

**Core Rule: Never delete — invalidate.**

When information changes, the old memory is not removed. It is marked with an `invalid_at` timestamp, and a new memory is created with a `supersedes` link pointing to the old one. This preserves the full history of how information evolved.

**Example:**

```json
{
  "id": "mem-001",
  "content": "Production server runs nginx 1.24",
  "valid_from": "2025-06-15",
  "invalid_at": "2026-01-20",
  "supersedes": null
}

{
  "id": "mem-002",
  "content": "Production server runs nginx 1.25",
  "valid_from": "2026-01-20",
  "invalid_at": null,
  "supersedes": "mem-001"
}
```

**Query Modes:**
- **Current state (default):** Return only memories where `invalid_at` is null. This is the standard mode for task execution — agents need current information.
- **Full timeline:** Return all memories for a given topic, ordered by `valid_from`. Used for answering questions like "When did we upgrade nginx?" or "What was the configuration before the change?"
- **Point-in-time:** Return memories valid at a specific date. Used for retrospective analysis.

## Storage Integration

Cognitive Memory is designed to work with any vector database that supports:
- Vector similarity search (for PE gating and recall)
- Metadata filtering (for temporal queries and category-based retention)
- CRUD operations on individual records

**Recall (RAG) Query Flow:**
1. Convert query to embedding vector
2. Search for similar memories with filter: `invalid_at = null` (current only, by default)
3. Rank results by: `similarity * importance * retention_probability`
4. Return top-K results with metadata

**Write Flow:**
1. Compute PE against existing memories
2. Apply gating action (CREATE, UPDATE, REINFORCE, or SUPERSEDE)
3. Compute 4-channel importance score
4. Set initial stability (S = 1.0 for new memories)
5. Store with bi-temporal metadata

## Integration Points

- **Input:** New information from agent task outputs, external data feeds, user corrections
- **Output:** Recalled memories injected into agent context during task execution
- **Related:** Metacognitive reflection produces memories (procedure and principle reflections are stored as memories)
- **Related:** Prompt Evolution consumes principle reflections extracted from memory patterns
- **Related:** Record & Replay trajectory pool is a specialized memory store with its own lifecycle rules
