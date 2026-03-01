# Cognitive Memory v8.1

Advanced memory system combining spaced repetition, multi-channel importance scoring, prediction error gating, hybrid search with RRF fusion, dream consolidation, strategic forgetting, utility scoring, and relational graphs. This system determines what agents remember, how long they remember it, when old memories should be updated or retired, and how they relate to each other.

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                     Cognitive Memory v8.1                       │
├──────────┬──────────┬───────────┬──────────┬──────────────────┤
│ Observer │ Formation│ PE Gate   │ Retrieval│ Dream Cycle      │
│          │          │           │ Router   │                  │
│ Message  │ Coref    │ CREATE    │ Intent   │ Consolidation    │
│ Analysis │ Atomic   │ UPDATE    │ Classify │ Forgetting       │
│ Entity   │ Temporal │ SUPERSEDE │ Strategy │ Redundancy       │
│ Classify │ Foresight│ REINFORCE │ Select   │ Abstraction      │
├──────────┴──────────┴───────────┼──────────┴──────────────────┤
│     Write Path                  │     Read Path               │
├─────────────────────────────────┼─────────────────────────────┤
│ Importance (4-ch) │ FSRS-6     │ HyDE Expansion │ Hybrid     │
│ Utility Scoring   │ Relations  │ ACT-R Activation│ MMR/RRF   │
├─────────────────────────────────┴─────────────────────────────┤
│                    LanceDB (Vector + FTS)                      │
│              + Ops Logger (JSONL telemetry)                    │
└───────────────────────────────────────────────────────────────┘
```

## Core Mechanisms (v6 Foundation)

### FSRS-6 Spaced Repetition

Models memory retention using power-law decay, based on the Free Spaced Repetition Scheduler version 6.

**Retention Formula:**
```
R = (1 + t / (9 * S))^(-1/0.5)
```

Where:
- `R` = retention probability (0.0 to 1.0)
- `t` = time elapsed since last access (days)
- `S` = stability (resistance to decay)

Power-law decay has a heavier tail than exponential — well-established memories retain meaningful probability even after long periods without access.

**Dual Strength Model (v8):**
```typescript
interface DualStrength {
  storage: number;    // 1.0-10.0 (no decay — how deeply encoded)
  retrieval: number;  // 0.0-1.0 (FSRS decay — current accessibility)
}
```

Storage strength increases with each successful retrieval. Retrieval strength decays over time but is restored on access. A memory can have high storage (deeply encoded) but low retrieval (not recently accessed) — this is the "tip of the tongue" state.

### 4-Channel Importance Scoring

| Channel | Weight | Description |
|---------|--------|-------------|
| Novelty | 0.25 | How new compared to existing memories? |
| Arousal | 0.30 | How urgent or critical? (errors, security, deadlines) |
| Reward | 0.25 | How useful has similar information been? |
| Attention | 0.20 | How relevant to current context? |

```
importance = (novelty * 0.25) + (arousal * 0.30) + (reward * 0.25) + (attention * 0.20)
```

Each channel: 0.0 to 1.0. Encoding boost multiplier (0.7-1.3) adjusts composite score. Priority levels: critical (>=0.8), high (>=0.6), normal (>=0.4), low (<0.4).

### Prediction Error (PE) Gating

Controls the write path using prediction error — how much new information differs from existing knowledge.

```
PE = 1.0 - similarity_to_closest_existing_memory
```

| PE Score | Action | Rationale |
|----------|--------|-----------|
| < 0.70 | CREATE | Sufficiently novel |
| 0.70 - 0.74 | (gap) | CREATE if importance high, else skip |
| 0.75 - 0.92 | UPDATE | Overlaps but adds detail |
| > 0.92 | REINFORCE | Nearly identical — boost stability |
| Contradiction | SUPERSEDE | Key values differ — invalidate old |

Cosine similarity (v8) replaces Jaccard for PE calculation, better suited for vector-embedded text.

### BCM Pruning

Floating threshold based on actual usage:
```
threshold = average(access_count across all memories)
```

Category-based minimum retention:
| Category | Min Retention |
|----------|---------------|
| Corrections | permanent |
| Preferences | permanent |
| Entities | permanent |
| Decisions | 45 days |
| Facts | 14 days |
| Other | 7 days |

---

## v8.1 Additions

### Hybrid Search (Vector + FTS + RRF Fusion)

Single query triggers two parallel search paths merged via Reciprocal Rank Fusion:

```
1. Vector search (3x overfetch for MMR pool)
2. FTS/BM25 text search (graceful fallback if no index)
3. RRF fusion: score = 1 / (K + rank + 1), K = 60
4. Merge unique results
5. Weighted composite:
   - 0.40 × similarity (vector distance)
   - 0.30 × ACT-R activation
   - 0.15 × importance
   - 0.15 × RRF score
6. Entity boost: +0.1 per matching entity
7. Episode boost: +0.15 for same session episode
8. MMR diversity re-rank
```

**ACT-R Activation Model:**
```
B = log(max(n, 1)) - 0.5 × log(age_seconds)
activation = 1 / (1 + exp(-B))
```
Where `n` = access count, `age` = seconds since last access. Models the base-level activation from cognitive psychology.

**Category Decay Rates:**
| Category | Decay/Day |
|----------|-----------|
| preference, entity, correction | 0 (no decay) |
| fact | 0.005 |
| decision | 0.02 |
| other | 0.05 |

### MMR Diversity Filtering

Maximal Marginal Relevance prevents redundant results:

```
MMR(d) = λ × relevance(d) - (1-λ) × max_similarity(d, selected)
```

- Lambda: 0.7 (70% relevance, 30% diversity)
- Iteratively selects documents maximizing information gain
- Uses text-based cosine similarity as diversity proxy

### HyDE Query Expansion

Hypothetical Document Embeddings — template-based, zero LLM cost.

**7 Intent Categories (EN + TR support):**
1. `definition` — what is X?
2. `howto` — how to X?
3. `reasoning` — why X?
4. `lookup` — where is X?
5. `technical` — debug/code/config
6. `preference` — likes/dislikes
7. `general` — fallback

Each intent generates 2-3 hypothetical document templates. Query + variants are embedded, then averaged into a centroid vector for search. This widens recall without any LLM calls.

### Observer Pipeline

Bidirectional message analysis — captures valuable information from both user and assistant messages.

**7-Layer Filtering:**
1. Length gate: 10 < length < 5000
2. System content detection (XML tags, heartbeat, system-reminder)
3. Prompt injection patterns ("ignore instructions", "system prompt")
4. XML-block structure skip
5. Markdown-heavy skip (5+ lines with bullets/bold)
6. Code-heavy skip (>50% code blocks)
7. Emoji-heavy skip (>3 emoji)

**Classification (pattern scoring):**
| Type | Trigger | Base Confidence |
|------|---------|----------------|
| Correction | "actually", "should be", "was wrong" | 0.4 |
| Preference | "prefer", "like/hate", "favorite" | 0.3 |
| Decision | "decided", "going with", "chose" | 0.35 |
| Entity-rich | 2+ entities detected | 0.3 |
| Fact | "my name", "version is", "api is" | 0.25 |

**Entity Extraction:** Regex NER for tech (React, Docker, PostgreSQL, etc.) and org (Google, Anthropic, etc.) entities. Max 8 per observation. Format: `entity://tech/{slug}` or `entity://org/{slug}`.

**Standalone Rewriting:** Converts first-person to third-person ("I prefer X" → "User prefers X"), removes filler words, max 500 chars.

### Dream Consolidation

Periodic memory lifecycle management — 8-step dream cycle:

1. **Utility Decay**: Unused memories drift toward 0.5 neutral prior
   - `newUtil = currentUtil + 0.01 × daysSince × (0.5 - currentUtil)`

2. **Rehearsal**: Endangered memories (FSRS R < 0.3) get stability boost (×1.5)

3. **Foresight Expiry**: Time-bounded memories past validUntil → superseded

4. **Strategic Forgetting**: 5-rule pipeline (see Strategic Forgetting section)

5. **Clustering**: Group by entity overlap (>=1) or category match + importance proximity (<0.3). Min 3 memories/cluster.

6. **LLM Consolidation**: Merge clusters via gpt-4o-mini (max 5 calls/cycle). Extract themes, create theme-level memories (importance 0.8), mark originals superseded.

7. **Redundancy Detection**: Cosine similarity > 0.9 → keep higher-utility, mark lower dormant. Max 50 comparisons per cycle.

8. **Deep Abstraction**: Extract behavioral patterns from top 3 clusters via LLM. Pattern-level memories at importance 0.85.

### A-MEM Spreading Activation

Neighbor evolution based on A-MEM paper — when a memory is accessed, connected memories receive a 2% stability boost via spreading activation. Entity crosslinks enable semantic activation beyond direct relations.

### Strategic Forgetting

Capacity-aware pruning with 5 ordered rules:

| Rule | Condition | Action |
|------|-----------|--------|
| Contradiction cleanup | Has `contradicts` relation | Older side → dormant |
| Foresight expiry | `time_bounded` + past `validUntil` | → dormant |
| Utility floor | utility < 0.15 AND 30+ days unused | → dormant |
| Redundancy | cosine > 0.9 with another memory | Lower-utility → dormant |
| Capacity trim | active count > 500 | Trim lowest-utility to 450 |

Dormant memories are not deleted — they move to cold storage and can be reactivated.

### Bellman-Style Utility Scoring

Three pure functions for memory usefulness tracking:

**Update on Use:**
```
utility = utility + α × (target - utility)
```
Where α = 0.1, target = 1.0 (success) or 0.0 (failure). Single bad session won't tank a high-utility memory.

**Temporal Decay:**
```
utility = utility + 0.01 × daysSince × (0.5 - utility)
```
High-utility memories slowly drift down, low-utility drift up toward 0.5 neutral prior.

**Weighted Retrieval Score:**
```
score = 0.6 × semantic + 0.2 × utility + 0.2 × importance
```
Relevance dominates (60%), utility and importance serve as tiebreakers.

### Relational Graph

Memory linking with 6 relation types:

| Type | Description | Prunable? |
|------|-------------|-----------|
| `supersedes` | Newer replaces older | No |
| `contradicts` | Conflicting information | No |
| `causes` | Causal relationship | No |
| `elaborates` | Adds detail | Yes (priority 2) |
| `same_entity` | Both about same entity | Yes (priority 1) |
| `related_to` | Loosely connected | Yes (priority 0) |

**Detection:** LLM-primary (gpt-4o-mini) with heuristic fallback:
- Entity overlap >= 2 → `same_entity` (0.7 confidence)
- Word overlap > 30% + entity >= 1 → `elaborates` (0.5)
- Same category + word overlap > 15% → `related_to` (0.4)

**Pruning:** Triggered at 1000 relations, trims to 900. Removes lowest-confidence pruneable types first. Never prunes supersedes/contradicts/causes.

**Traversal:** BFS with configurable max hops and type filters. Entity hub queries find all memories mentioning a specific entity.

### Bi-Temporal Lifecycle

Every memory carries two temporal dimensions:

| Field | Description |
|-------|-------------|
| `validFrom` | When information became true |
| `validUntil` | When it stops being true (null if persistent) |
| `recordedAt` | When system stored it |
| `supersedes` | Link to older memory |
| `temporalType` | `persistent` or `time_bounded` |

**Core Rule: Never delete — invalidate.**

Query modes: current state (default, validUntil = null), full timeline, point-in-time.

### Enriched Formation

Transforms raw observations into structured memory units:

**LLM Path (primary):** Haiku model for coreference resolution, atomic fact splitting, temporal normalization, foresight detection, entity extraction, and category classification.

**Heuristic Fallback:**
- Coreference: pronouns → last known entity (EN + TR)
- Atomic split: " and "/" ve " with different entities on each side
- Temporal: bugün→today, yarın→tomorrow, dün→yesterday → ISO dates
- Foresight: "plan to", "will", "going to" → validUntil = +7 days default

Output:
```typescript
{
  atomicFacts: string[];
  foresightSignals: ForesightSignal[];
  temporalType: "persistent" | "time_bounded";
  validUntil: number;
  resolvedText: string;
  entities: string[];
  category: "preference" | "fact" | "decision" | "correction" | "plan" | "entity";
}
```

### Intent-Based Retrieval Routing

Classifies query intent and selects optimal retrieval strategy:

| Intent | Primary Method | Sort | Special |
|--------|---------------|------|---------|
| factual | hybrid | relevance | utility boost: 0.2 |
| temporal | hybrid | validFrom desc | include superseded |
| causal | graph traversal | relevance | causes/elaborates, 2 hops |
| entity_profile | entity hub | utility desc | utility boost: 0.3 |
| preference | hybrid + filter | utility desc | category: preference, correction |
| general | hybrid | relevance | utility boost: 0.2 |

Classification: LLM-primary (gpt-4o-mini) with keyword heuristic fallback (EN + TR patterns).

### Operational Logging

Fire-and-forget JSONL telemetry for all LLM-assisted decisions.

**Log Path:** `~/.agent-evolution/memory/ops-log.jsonl`
**Rotation:** 10MB per file → `ops-log-{YYYY-MM-DD}.jsonl`

```json
{
  "ts": "2026-03-01T12:00:00Z",
  "op": "consolidation",
  "input": "cluster of 5 memories about API routing...",
  "output": "merged into 1 theme memory",
  "model": "gpt-4o-mini",
  "latencyMs": 450,
  "success": true,
  "fallback": false,
  "intent": "technical",
  "avgRelevance": 0.72,
  "resultCount": 5
}
```

Zero latency impact — async append with error swallowing.

---

## Write Flow (Complete)

```
Message → Observer (filter + classify) → Formation (enrich + split)
  → PE Gate (create/update/supersede/reinforce)
  → Importance (4-channel score) → Utility (init 0.5)
  → Relations (detect links) → Store (LanceDB + metadata)
  → Ops Log (async telemetry)
```

## Read Flow (Complete)

```
Query → Intent Router (classify intent) → HyDE (expand query, 2-3 variants)
  → Hybrid Search (vector + FTS) → RRF Fusion (K=60)
  → ACT-R Activation → Entity/Episode Boost
  → MMR Re-rank (λ=0.7) → Return top-K
```

## Academic Foundations

| Paper | Contribution to System |
|-------|----------------------|
| FSRS-6 (Open Spaced Repetition) | Power-law retention decay model |
| ACT-R (Anderson et al.) | Base-level activation for retrieval ranking |
| BCM Theory (Bienenstock-Cooper-Munro) | Adaptive pruning threshold |
| HyDE (Gao et al., 2022) | Query expansion via hypothetical documents |
| MMR (Carbonell & Goldstein, 1998) | Diversity filtering in retrieval |
| RRF (Cormack et al., 2009) | Rank fusion for hybrid search |
| A-MEM (2024) | Spreading activation for memory evolution |

## Integration Points

- **Input:** Agent messages (observer), task outputs, user corrections, external feeds
- **Output:** Retrieved memories injected into agent context during task execution
- **Dream Cycle:** Periodic consolidation via `dream` command (recommended: daily)
- **Compaction:** Memory dedup and index optimization via `compact` command
- **Related:** Metacognitive Reflection produces memories; Prompt Evolution consumes patterns
- **Related:** Trajectory Pool and Record & Replay maintain separate lifecycle rules
