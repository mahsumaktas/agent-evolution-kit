# Cognitive Memory v9

Advanced memory system combining spaced repetition, multi-channel importance scoring, prediction error gating, hybrid search with RRF fusion, dream consolidation, strategic forgetting, utility scoring, relational graphs, synaptic tagging, emotional memory, hierarchical tiers, and working memory. This system determines what agents remember, how long they remember it, when old memories should be updated or retired, how they relate to each other, and how they organize into cognitive tiers.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                      Cognitive Memory v9                          │
├──────────┬──────────┬───────────┬──────────┬────────────────────┤
│ Observer │ Formation│ PE Gate   │ Retrieval│ Dream Cycle        │
│          │          │           │ Router   │                    │
│ Message  │ Coref    │ CREATE    │ Intent   │ Consolidation      │
│ Analysis │ Atomic   │ UPDATE    │ Classify │ Forgetting         │
│ Entity   │ Temporal │ SUPERSEDE │ Strategy │ Redundancy         │
│ Classify │ Foresight│ REINFORCE │ Select   │ Abstraction        │
│ Emotion  │          │ SKIP(gate)│ Decompose│ Tier Promo/Demo    │
├──────────┴──────────┴───────────┼──────────┴────────────────────┤
│     Write Path                  │     Read Path                 │
├─────────────────────────────────┼───────────────────────────────┤
│ Importance (4-ch) │ FSRS-6     │ HyDE Expansion │ Hybrid       │
│ Utility Scoring   │ Relations  │ ACT-R Activation│ MMR/RRF     │
│ Synaptic Tagging  │ Emotional  │ Sub-Tier Boost  │ Hot Tier    │
│ Source Confidence  │ Hierarchy  │ Pre-Retrieval   │ Embedding   │
│                    │            │ Gate            │ Cache       │
├─────────────────────────────────┴───────────────────────────────┤
│                    LanceDB (Vector + FTS)                        │
│   + Ops Logger (JSONL) + Embedding Cache (LRU, 200 entries)     │
└─────────────────────────────────────────────────────────────────┘
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

2. **Rehearsal**: Endangered memories (FSRS R < 0.3) get stability boost (x1.5)

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

## v9 Additions (Phase 0-4)

### Phase 0: Critical Bug Fixes

10 fixes addressing stability and correctness issues discovered under multi-agent production load.

| Bug | Fix | Impact |
|-----|-----|--------|
| B1: Session-scoped state | Global Maps replaced with per-session Maps | Prevents cross-agent data leaks in multi-agent setups |
| B2: Importance counter | Initialization bug fixed — counter was not reset between cycles | Correct importance scoring on all memories |
| B3: Observer confidence | Source confidence now propagated to stored memories | Memories carry provenance quality signal |
| B4: Dream cycle OOM | 500 memory cap enforced per consolidation batch | Prevents out-of-memory on large memory stores |
| B5: Relation dedup | Duplicate relation detection before insert | Reduces graph bloat |
| B6: Ops-logger rotation | Rotation logic fixed for edge cases | Prevents unbounded log growth |
| B7: HyDE Turkish support | Turkish intent patterns added to HyDE templates | Correct query expansion for TR queries |
| B8: Config schema wiring | Schema validation connected to runtime config | Catches invalid config at startup |
| B9: Table scan optimization | Index usage enforced for frequent query patterns | Eliminates full table scans on large stores |
| B10: Minor fixes | Assorted null checks, type corrections, edge cases | General stability |

### Phase 1: Schema Foundation & Quick Wins

**Truth Anchors:**

Two protection flags that override all forgetting and consolidation logic:

```typescript
interface TruthAnchor {
  pinned: boolean;     // User-protected — survives all forgetting operations
  immutable: boolean;  // System-protected — cannot be edited, consolidated, or demoted
}
```

Pinned memories survive strategic forgetting, capacity trim, and demotion. Immutable memories additionally cannot be modified by UPDATE or consolidation merges. Both flags are independent — a memory can be pinned but not immutable, or both.

**Uncertainty Tracking:**

```typescript
interface UncertaintyTracking {
  sourceConfidence: number;  // 0.0-1.0, propagated from observer
  writeSource: string;       // "observer" | "formation" | "dream" | "manual"
  dataSource: string;        // "user_message" | "assistant_message" | "system" | "federation"
}
```

Source confidence modulates retrieval scoring — low-confidence memories (< 0.3) are deprioritized in ranking. Write source and data source track full provenance chain.

**Pre-Retrieval Gate:**

Pattern-based skip logic that short-circuits the full retrieval pipeline for trivial messages:

- Greetings ("hi", "hello", "merhaba", "selam")
- Confirmations ("ok", "sure", "tamam", "evet")
- Slash commands ("/help", "/status", "/dream")
- Single-word acknowledgements

Saves embedding API calls on messages that don't need memory lookup. Applied before HyDE expansion.

**Embedding Cache:**

LRU cache for OpenAI embedding API calls:

| Parameter | Value |
|-----------|-------|
| Max entries | 200 |
| TTL | 30 minutes |
| Key | SHA-256 hash of input text |
| Eviction | Least Recently Used |

Eliminates redundant API calls for repeated or similar queries within a session. Cache is session-scoped — cleared on session end.

**Testing Effect Cron:**

Periodic rehearsal of endangered memories based on the testing effect from cognitive psychology — the act of retrieving a memory strengthens it more than passive re-exposure.

- Trigger: Cron schedule (configurable, default daily)
- Target: Memories with FSRS retention < 0.3
- Action: Stability boost (x1.5) simulating successful retrieval
- Cap: Max 50 memories per cycle to bound compute

### Phase 2: Memory Intelligence — Read & Write Path

**Confidence-Gated Dynamic Injection:**

Memory injection into agent context adjusts based on retrieval confidence:

| Confidence Range | Injection Style |
|-----------------|-----------------|
| >= 0.7 | Full injection — complete memory text with metadata |
| 0.4 - 0.7 | Abbreviated — summary only, no metadata |
| < 0.4 | Skipped — not injected, logged as low-confidence hit |

Prevents hallucination amplification from borderline memory matches.

**Information Density Scoring:**

Rates how much new information a message contains before committing to the full capture pipeline:

```
density = unique_entities + unique_facts + temporal_signals + correction_signals
```

Messages with density < 2 are skipped at the observer level. This reduces write-path load for conversational filler ("sounds good", "let me think about that").

**Write-Time Synthesis:**

When the PE gate returns UPDATE, the existing memory text is merged with new information rather than replaced:

1. Retrieve existing memory text
2. LLM merge (gpt-4o-mini): combine old + new, preserve all facts, resolve contradictions
3. Update text, bump accessCount, refresh timestamp
4. Heuristic fallback: append new text with separator if LLM unavailable

This preserves historical context that would otherwise be lost on UPDATE.

**Multi-Query Decomposition:**

Complex queries are split into independent sub-queries for better recall:

1. Detect compound queries (multiple question marks, "and also", conjunctions with distinct entities)
2. Split into 2-4 sub-queries
3. Run each sub-query through the full retrieval pipeline independently
4. Merge results via RRF fusion across sub-query result sets
5. Deduplicate by memory ID

**Retrieval Strategy Router:**

Full implementation of intent-based routing with optimized parameters per intent:

| Intent | Vector Weight | FTS Weight | Limit | Special Handling |
|--------|--------------|-----------|-------|------------------|
| factual | 0.6 | 0.4 | 10 | Utility boost 0.2 |
| temporal | 0.4 | 0.6 | 15 | Sort by validFrom, include superseded |
| causal | 0.3 | 0.3 | 20 | Graph traversal primary, 2 hops |
| entity_profile | 0.5 | 0.5 | 15 | Entity hub query, utility boost 0.3 |
| preference | 0.5 | 0.5 | 10 | Category filter: preference, correction |
| general | 0.5 | 0.5 | 10 | Balanced defaults |

### Phase 3: Revolutionary Features

**Synaptic Tagging & Capture:**

Inspired by the synaptic tagging and capture (STC) hypothesis from neuroscience. In biological memory, weak synaptic changes ("tags") can be stabilized by plasticity-related proteins generated by nearby strong events.

Implementation:

1. **Tagging**: When a memory is stored with importance < 0.5 (weak), it receives a synaptic tag with a 4-hour TTL
2. **Capture**: If a strong memory (importance >= 0.7) is stored within the tag TTL, all tagged memories in the same session get a stability boost (x1.3)
3. **Hebbian Co-activation**: Memories retrieved together in the same query get strengthened together — accessCount incremented, stability boosted by 2%. This builds associative networks over time.
4. **Co-activation Tracking**: A co-activation map tracks which memory pairs are frequently retrieved together. Pairs with co-activation count >= 3 receive a retrieval boost (0.05) when either is a search result.

```typescript
interface SynapticTag {
  memoryId: string;
  taggedAt: number;     // timestamp
  ttlMs: number;        // 4 hours default
  sessionId: string;
  captured: boolean;    // true once stabilized by a strong event
}
```

**Emotional Memory System:**

Detects emotional valence and arousal in messages, creating differentiated memory handling for emotionally significant events.

**Emotion Detection:**

Pattern-based detection (no LLM cost) across EN and TR:

| Dimension | Detection Method |
|-----------|-----------------|
| Valence | Positive/negative keyword lists (EN + TR) |
| Arousal | Exclamation marks, caps, urgency words, profanity |
| Category | joy, anger, fear, sadness, surprise, disgust (Ekman basic) |

**Flashbulb Memories:**

High-arousal events (arousal >= 0.8) create flashbulb memories — vivid, persistent, automatically protected:

- Pinned: true (immune to forgetting)
- Importance: min 0.9 (overrides calculated importance if lower)
- Stability: x1.5 boost (enhanced encoding)
- Tag: `flashbulb: true` in metadata

Modeled after Brown & Kulik's flashbulb memory theory — emotionally charged events receive preferential encoding and storage.

**Mood-Congruent Retrieval:**

When user mood is detected from the current message, emotionally matching memories receive a retrieval relevance boost:

```
if (currentMood && memory.emotionalValence) {
  if (sameValence(currentMood, memory.emotionalValence)) {
    score *= 1.1;  // 10% boost for mood-congruent memories
  }
}
```

This models the mood-congruent memory effect from cognitive psychology — people are more likely to recall memories that match their current emotional state.

**4-Phase Dream Consolidation:**

Extended from the v8.1 8-step cycle to include emotional consolidation and synaptic replay:

1. **PAHF Tier-Based Decay**: Apply tier-specific decay multipliers (see Phase 4)
2. **Emotional Consolidation**: Flashbulb memories get stability boost, emotional tags consolidated
3. **Synaptic Replay**: Co-activated memory pairs get strengthened, expired tags cleaned up
4. **Promotion/Demotion Evaluation**: Memories evaluated for tier transitions (see Phase 4)
5-8. Original v8.1 steps: utility decay, rehearsal, foresight expiry, strategic forgetting, clustering, LLM consolidation, redundancy detection, deep abstraction

**Category Summary System:**

Auto-generates and maintains per-category summary memories:

1. Triggered when a category accumulates 10+ active memories
2. LLM generates a concise summary of all memories in that category
3. Summary stored as a semantic-tier memory with importance 0.8
4. Debounced: 60-second cooldown per category to prevent LLM call storms
5. Fire-and-forget: non-blocking, errors logged but don't interrupt main flow
6. Summaries are updated (not duplicated) on subsequent triggers

### Phase 4: Hierarchy Completion

**Memory Tier System** — Adapted from Tulving's episodic/semantic taxonomy and the PAHF (Personalized Adaptive Hierarchical Forgetting) model.

```
┌─────────────────────────────────────────────────────────┐
│                    Memory Tiers                          │
├──────────┬──────────┬───────────┬───────────────────────┤
│ Working  │ Episodic │ Semantic  │ Dormant               │
│ (active  │ (recent  │ (proven   │ (cold storage,        │
│  session)│  events) │  knowledge)│  reactivatable)      │
├──────────┼──────────┼───────────┼───────────────────────┤
│ Max 9    │ Default  │ Promoted  │ Demoted or            │
│ items    │ tier for │ from      │ strategically         │
│ (Miller) │ captures │ episodic  │ forgotten             │
├──────────┼──────────┼───────────┼───────────────────────┤
│ Decay:   │ Decay:   │ Decay:    │ Decay:                │
│ 10x      │ 3x       │ 1x        │ N/A (frozen)          │
│ (fast)   │ (normal) │ (slow)    │                       │
└──────────┴──────────┴───────────┴───────────────────────┘
```

**Working Memory (Session-Scoped):**

In-session buffer for the most immediately relevant memories. Modeled after Miller's "magical number seven, plus or minus two" — capped at the upper bound of 9 items.

- Max 9 items per session (Miller's 7+/-2 upper bound)
- Eviction by composite score: `importance * recency * (1 + accessCount * 0.1)`
- Recency uses exponential decay with 30-minute half-life
- Duplicate IDs update in-place (no eviction triggered)
- Promotion candidates: `accessCount >= 2` OR `importance >= 0.6`
- Cleared on session end via `finally` block (guaranteed cleanup)

```typescript
interface WorkingMemoryEntry {
  id: string;
  text: string;
  importance: number;
  accessCount: number;
  addedAt: number;
  lastAccessed: number;
}

// Eviction score calculation
function evictionScore(entry: WorkingMemoryEntry, now: number): number {
  const ageMinutes = (now - entry.lastAccessed) / 60000;
  const recency = Math.exp(-ageMinutes / 30);  // 30-min half-life
  return entry.importance * recency * (1 + entry.accessCount * 0.1);
}
```

**Promotion Logic (Episodic → Semantic):**

Three independent rules — any match triggers promotion:

| Rule | Condition | Rationale |
|------|-----------|-----------|
| Access frequency | `accessCount >= 3` | Repeatedly accessed = valuable |
| Sustained utility | `utility >= 0.7` AND `age >= 7 days` | Consistently useful over time |
| Entity co-occurrence | `>= 3` episodic memories share an entity | Convergent evidence = semantic knowledge |

Exemptions: pinned and immutable memories are never promoted (they stay where they are by design).

**Demotion Logic (Semantic → Dormant):**

| Condition | Threshold |
|-----------|-----------|
| Idle period | `>= 60 days` since last access |
| Low utility | `< 0.2` utility score |
| Both required | AND logic — both must be true |

Exemptions: pinned, immutable, and flashbulb memories are immune to demotion.

**PAHF Tier-Based Decay:**

Based on the Personalized Adaptive Hierarchical Forgetting model. Different tiers decay at different rates during dream consolidation:

| Tier | Multiplier | Effect |
|------|-----------|--------|
| Working | 10x | Rapid decay — session-local, ephemeral |
| Episodic | 3x | Normal decay — recent events fade naturally |
| Semantic | 1x | Slow decay — proven knowledge persists |
| Dormant | N/A | No decay — frozen in cold storage |

Applied during dream consolidation step 1. The multiplier scales the base decay rate — higher multiplier means faster forgetting.

**Hot Tier (Always-Inject):**

A virtual tier — the top semantic memories that are always injected into agent context, regardless of query relevance. These represent the agent's core knowledge that should always be available.

Selection criteria:

| Filter | Default |
|--------|---------|
| Utility | >= 0.8 |
| Access count | >= 10 |
| Age | < 30 days |
| State | active |
| Max items | 15 |

Results are TTL-cached (5 minutes) to avoid per-request DB queries. Sorted by utility descending. Hot tier is recalculated on cache expiry.

**Sub-Tier Classification:**

Episodic sub-tiers (based on source):

| Sub-tier | Trigger | Retrieval Boost |
|----------|---------|-----------------|
| Personal | User message or user-attributed | 1.1x |
| Observed | Agent inference or conversation | 1.0x (baseline) |
| Vicarious | Federation (cross-agent) | 0.9x |

Semantic sub-tiers (based on content):

| Sub-tier | Trigger | Retrieval Boost |
|----------|---------|-----------------|
| Schematic | Category "pattern" or contains "always/never/rule" | 1.1x |
| Procedural | Category "procedure/skill" or "how to" pattern | 1.05x |
| Factual | Default | 1.0x (baseline) |

Sub-tier boosts are applied during the retrieval scoring phase, after RRF fusion and before MMR re-ranking.

---

## Write Flow (Complete)

```
Message → Observer (filter + classify + emotion detect)
  → Pre-Retrieval Gate (skip trivial messages)
  → Formation (enrich + split + confidence propagate)
  → PE Gate (create/update/supersede/reinforce/skip)
  → Importance (4-channel score) → Utility (init 0.5)
  → Synaptic Tagging (tag weak, capture near strong)
  → Relations (detect links) → Store (LanceDB + metadata + tier assignment)
  → Working Memory (add if session-relevant)
  → Ops Log (async telemetry)
```

## Read Flow (Complete)

```
Query → Pre-Retrieval Gate (skip trivial)
  → Intent Router (classify intent)
  → Multi-Query Decomposition (split compound queries)
  → HyDE (expand query, 2-3 variants) → Embedding Cache (LRU check)
  → Hybrid Search (vector + FTS) → RRF Fusion (K=60)
  → ACT-R Activation → Entity/Episode Boost → Sub-Tier Boost
  → Confidence-Gated Injection (full/abbreviated/skip)
  → Hebbian Co-activation (strengthen co-retrieved memories)
  → MMR Re-rank (λ=0.7) → Hot Tier Merge → Return top-K
```

---

## Roadmap

### Completed (Phase 0-4)

Individual cognitive memory — an agent that remembers, forgets intelligently, organizes knowledge into tiers, consolidates during dream cycles, and tags emotional significance.

### In Progress (Phase 5-11)

| Phase | Feature | Status |
|-------|---------|--------|
| 5 | Cross-Agent Federation — shared memory with access control | Planned |
| 6 | Governance & Safety — PII detection, audit trails, write authorization | Planned |
| 7 | Gateway Hardening — self-healing, WebSocket security, state migration | Planned |
| 8 | Infrastructure & UX — MCP memory server, observability dashboard | Planned |
| 9 | Skill Memory — track skill performance, mine workflow patterns | Planned |
| 10 | Research Extensions I — AMA-Bench evaluation, HippoRAG personalized retrieval | Planned |
| 11 | Research Extensions II — prospective memory, semantic compression, hippocampal replay | Planned |

---

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
| PAHF (2024) | Personalized Adaptive Hierarchical Forgetting for tier-based decay |
| Tulving (1972) | Episodic/semantic memory distinction |
| STC (Frey & Morris, 1997) | Synaptic Tagging and Capture hypothesis |
| Miller (1956) | The magical number seven, plus or minus two |
| Ebbinghaus (1885) | Forgetting curve |

## Integration Points

- **Input:** Agent messages (observer), task outputs, user corrections, external feeds
- **Output:** Retrieved memories injected into agent context during task execution
- **Dream Cycle:** Periodic consolidation via `dream` command (recommended: daily)
- **Compaction:** Memory dedup and index optimization via `compact` command
- **Related:** Metacognitive Reflection produces memories; Prompt Evolution consumes patterns
- **Related:** Trajectory Pool and Record & Replay maintain separate lifecycle rules
