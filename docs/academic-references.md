# Academic References

> This document summarizes the 10 academic papers that form the theoretical foundation of the Agent Evolution Kit. Each entry describes the paper's core contribution, how we implement it, and what we adapted from the original design.

---

## Table of Contents

1. [Reflexion](#1-reflexion)
2. [MAR: Multi-Agent Reflexion](#2-mar-multi-agent-reflexion)
3. [SCOPE: Dual-Stream Prompt Evolution](#3-scope-dual-stream-prompt-evolution)
4. [SE-Agent: Self-Evolving Agents](#4-se-agent-self-evolving-agents)
5. [MARS: Metacognitive Agents](#5-mars-metacognitive-agents)
6. [AgentRR: Record and Replay](#6-agentrr-record-and-replay)
7. [SimpleMem: Memory-Augmented Agents](#7-simplemem-memory-augmented-agents)
8. [Evolving Orchestration](#8-evolving-orchestration-of-multi-agent-systems)
9. [ToolOrchestra: Preference-Aware Orchestration](#9-toolorchestra-preference-aware-orchestration)
10. [AgentOrchestra: TEA Protocol](#10-agentorchestra-tea-protocol)
11. [Further Reading](#further-reading)

---

### 1. Reflexion

**Citation:** Shinn, N. et al. "Reflexion: Language Agents with Verbal Reinforcement Learning." _NeurIPS 2023._ [arXiv:2303.11366](https://arxiv.org/abs/2303.11366)

**Key Idea:** Agents produce natural-language reflections after task failures, store them in an episodic memory buffer, and inject the most recent reflections into future prompts as in-context learning signals. This enables trial-and-error improvement without any gradient-based weight updates. The approach demonstrates that verbal self-critique alone can close much of the performance gap between a naive agent and one fine-tuned on demonstrations.

**Our Implementation:** The [Reflexion Protocol](reflexion-protocol.md) mandates a structured reflection after every failed or partially completed task. Reflections follow a 5-field format (task, outcome, root cause, lesson, next action) and are persisted to the agent's reflection store. At inference time, the three most recent reflections matching the current task domain are injected into the system prompt.

**Adaptations:**
- The original paper uses a binary success/fail signal from an external evaluator. We replace this with a hybrid heuristic + LLM evaluation that produces a richer outcome taxonomy (FAILED, PARTIAL, SUCCESS) plus an optional decision reflection type.
- The paper stores all reflections indefinitely. We cap the active window at 3 reflections per agent and archive older entries to prevent prompt bloat.
- We add mandatory reflection on partial successes, not only on outright failures.

---

### 2. MAR: Multi-Agent Reflexion

**Citation:** Li, Y. et al. "Multi-Agent Reflexion for Collaborative Problem Solving." _arXiv preprint, 2024._ [arXiv:2512.20845](https://arxiv.org/abs/2512.20845)

**Key Idea:** Single-agent reflection has a blind-spot problem: an agent cannot critique assumptions it does not recognize as assumptions. MAR introduces a cross-agent review loop where a separate agent with different domain expertise critiques the output, surfaces overlooked issues, and feeds structured feedback back to the producer for revision. This multi-perspective approach consistently outperforms single-agent reflection on complex, multi-step tasks.

**Our Implementation:** The [Cross-Agent Critique Protocol](cross-agent-critique.md) defines a producer-reviewer matrix where each agent is assigned a reviewer from a different specialization. When a task meets the critique threshold (high-stakes output, external-facing content, or tasks exceeding a complexity score), the output is routed to the designated reviewer before finalization.

**Adaptations:**
- The paper proposes open-ended multi-agent discussion rounds. We constrain the loop to a single critique-revise cycle to control latency and cost.
- We assign fixed reviewer pairings via a static matrix rather than dynamic selection, trading flexibility for predictability and auditability.
- Critique results feed into both the producer's reflection store and the system-wide trajectory pool, creating a learning signal that the original paper does not address.

---

### 3. SCOPE: Dual-Stream Prompt Evolution

**Citation:** Wang, Z. et al. "SCOPE: Optimizing LLM Agents via Dual-Stream Prompt Evolution." _arXiv preprint, 2024._ [arXiv:2512.15374](https://arxiv.org/abs/2512.15374)

**Key Idea:** Agent prompts improve through two parallel streams. The tactical stream extracts immediate corrective rules from recent failures (e.g., "always validate date format before API call"). The strategic stream distills long-term principles from patterns across many successful executions (e.g., "decompose multi-entity queries into single-entity sub-queries"). Both streams feed into the agent's system prompt, with tactical rules providing fast adaptation and strategic principles providing stable guidance.

**Our Implementation:** The prompt evolution system described in the [Self-Evolution Playbook](self-evolution-playbook.md) (Section 4) maintains two rule buffers per agent. Tactical rules are extracted from each failed task reflection and capped at 10 per agent. Strategic rules are synthesized during the weekly evolution cycle by analyzing the trajectory pool for recurring success patterns, capped at 5 per agent. Both buffers are injected into the agent's system prompt at inference time.

**Adaptations:**
- The paper uses automated prompt mutation and tournament selection. We replace this with a simpler extract-and-accumulate approach because our agent count is small enough for manual curation during weekly cycles.
- We enforce hard caps (10 tactical, 5 strategic) to prevent unbounded prompt growth. The paper does not specify a retention policy.
- Strategic rule extraction is batched into the weekly cycle rather than running continuously, reducing LLM call overhead.

---

### 4. SE-Agent: Self-Evolving Agents

**Citation:** Zhang, H. et al. "SE-Agent: Self-Evolving Agents with Trajectory Management." _arXiv preprint, 2025._ [arXiv:2508.02085](https://arxiv.org/abs/2508.02085)

**Key Idea:** SE-Agent introduces three evolution operators applied to a trajectory pool of past task executions. Revision generates an orthogonal retry strategy for failed tasks. Recombination synthesizes a new approach by merging successful elements from two different trajectories. Refinement extracts risk-aware guidance from failure patterns and injects it as preventive advice into future similar tasks. Together, these operators allow the agent to improve without retraining.

**Our Implementation:** The trajectory learning system maintains a capped pool of 100 trajectory records (see [Architecture](architecture.md), Section 6). Each record captures the task, approach, outcome, and extracted lessons. The weekly evolution cycle applies the three operators: revision candidates are identified from failed trajectories, recombination is attempted across trajectories with overlapping task types, and refinement rules are distilled into the prompt evolution strategic stream.

**Adaptations:**
- The paper operates on a single agent. We extend the trajectory pool to be shared across all agents, enabling cross-agent recombination that the original design does not consider.
- We impose a 100-record cap with monthly archival. The paper does not address pool size management, which becomes critical in long-running systems.
- Revision is triggered only when manual retry is requested, not automatically, to avoid unbounded compute on persistently failing tasks.

---

### 5. MARS: Metacognitive Agents

**Citation:** Chen, W. et al. "MARS: Metacognitive Agents with Reflective Strategy." _arXiv preprint, 2026._ [arXiv:2601.11974](https://arxiv.org/abs/2601.11974)

**Key Idea:** Standard reflection extracts a single lesson from each experience. MARS argues this is insufficient and proposes dual extraction: a principle (a normative rule about what should always or never be done) and a procedure (a replicable step-by-step sequence that led to success or would have prevented failure). This metacognitive separation allows the system to build both a rule library and a playbook library from the same reflection events.

**Our Implementation:** The metacognitive reflection system (see [Architecture](architecture.md), Section 9) extends the standard reflection format with explicit principle and procedure fields. Each reflection call produces both outputs. Principles feed into the SCOPE strategic stream. Procedures feed into the Record and Replay system as high-level strategy templates. This dual routing ensures that every learning event contributes to both normative guidance and operational knowledge.

**Adaptations:**
- The paper uses a dedicated metacognitive module separate from the agent. We integrate dual extraction directly into the existing reflection protocol to avoid adding another LLM call.
- Procedures in the paper are free-form text. We impose a structured format (numbered steps with preconditions and expected outcomes) to make them machine-parseable for the Record and Replay system.
- We combine MARS extraction with SCOPE classification, tagging each principle as either tactical or strategic at extraction time.

---

### 6. AgentRR: Record and Replay

**Citation:** Liu, J. et al. "AgentRR: Record and Replay for LLM-Based Agents." _arXiv preprint, 2025._ [arXiv:2505.17716](https://arxiv.org/abs/2505.17716)

**Key Idea:** AgentRR proposes two-level experience storage for agent systems. The low level records step-by-step execution traces (tool calls, observations, decisions). The high level stores strategy summaries that abstract over multiple low-level executions. When facing a new task, the agent retrieves relevant high-level strategies for planning and low-level traces for execution guidance. This dual-granularity retrieval significantly outperforms either level alone.

**Our Implementation:** The Record and Replay system (see [Architecture](architecture.md), Section 8) uses the trajectory pool JSON format to store both levels. Each trajectory record contains a `steps` array (low-level trace) and a `strategy` field (high-level summary). At task time, the system retrieves by cosine similarity over task descriptions and injects the top-k matches as context.

**Adaptations:**
- The paper uses a dedicated vector database for retrieval. We use the trajectory pool's JSON structure with text-based similarity matching, trading retrieval precision for operational simplicity.
- Low-level traces in the paper capture every intermediate observation. We record only tool calls and their outcomes to keep trace size manageable.
- The paper's replay mechanism re-executes recorded traces. We use traces as advisory context only -- the agent is free to deviate from recorded strategies when the current task differs.

---

### 7. SimpleMem: Memory-Augmented Agents

**Citation:** Park, J. et al. "SimpleMem: Simple Yet Effective Memory-Augmented Agents." _arXiv preprint, 2026._ [arXiv:2601.02553](https://arxiv.org/abs/2601.02553)

**Key Idea:** SimpleMem challenges the prevailing trend toward complex memory architectures (hierarchical stores, episodic/semantic/procedural splits, attention-weighted retrieval). Through systematic ablation studies, it demonstrates that straightforward retrieval patterns -- recency-weighted keyword matching and simple importance scoring -- match or outperform architecturally complex alternatives on standard agent benchmarks. The paper argues that memory system complexity should be justified by measured gains, not assumed.

**Our Implementation:** The cognitive memory system described in the [Self-Evolution Playbook](self-evolution-playbook.md) adopts SimpleMem's philosophy of justified complexity. The base layer uses FSRS-6 spaced repetition for retention scheduling and a 4-channel importance score (novelty, arousal, reward, attention) for prioritization. Retrieval is keyword-based with recency weighting, aligning with the paper's finding that simple retrieval suffices.

**Adaptations:**
- We add FSRS-6 power-law decay scheduling, which the paper does not address. This gives us principled retention timing rather than the paper's static recency window.
- The 4-channel importance scoring goes beyond the paper's single-score approach, but each channel is independently simple, consistent with the paper's principle of compositional simplicity.
- We include category-based minimum retention periods (e.g., corrections persist longer than ephemeral facts), which is domain-specific policy not covered in the paper.

---

### 8. Evolving Orchestration of Multi-Agent Systems

**Citation:** Wu, L. et al. "Evolving Orchestration of Multi-Agent Systems." _arXiv preprint, 2025._ [arXiv:2505.19591](https://arxiv.org/abs/2505.19591)

**Key Idea:** Most multi-agent systems use static orchestration: fixed routing rules, predetermined delegation patterns. This paper proposes an orchestration layer that evolves its own routing and delegation strategies based on observed agent performance. The orchestrator tracks success rates, latency, and cost per agent per task type, then adjusts routing weights and delegation modes over time. This allows the system to adapt to changing agent capabilities without manual reconfiguration.

**Our Implementation:** The weekly self-evolution cycle (see [Architecture](architecture.md), Section 3, and [Self-Evolution Playbook](self-evolution-playbook.md), Section 3) implements orchestration evolution. During each cycle, the system analyzes the trajectory pool for per-agent performance metrics, updates capability-based routing scores (see [Architecture](architecture.md), Section 19), and adjusts delegation preferences. Changes are logged in the evolution log for auditability and rollback.

**Adaptations:**
- The paper proposes continuous online adaptation. We batch evolution into a weekly cycle to maintain stability and allow human review of proposed changes.
- Routing weight updates in the paper are gradient-based. We use heuristic score adjustments (increment on success, decrement on failure, bounded range) for transparency.
- We add a circuit breaker mechanism (see [Architecture](architecture.md), Section 18) that the paper does not include, preventing cascading failures when an agent degrades.

---

### 9. ToolOrchestra: Preference-Aware Orchestration

**Citation:** "ToolOrchestra: Preference-Aware Orchestration for Multi-Tool Agents." _arXiv preprint, 2025._ [arXiv:2511.21689](https://arxiv.org/abs/2511.21689)

**Key Idea:** When multiple tools or agents can fulfill a request, selection should consider multi-dimensional preferences rather than a single quality score. ToolOrchestra introduces preference vectors across quality, cost, and speed dimensions. Each tool is profiled with a capability vector, and routing decisions optimize for the caller's stated preference weights. This enables the same system to serve latency-sensitive interactive use cases and quality-sensitive batch use cases without reconfiguration.

**Our Implementation:** The preference-aware routing system (see [Architecture](architecture.md), Section 1) assigns each agent a `[Quality, Cost, Speed]` capability vector. Task routing computes a weighted match between the task's preference profile and available agent vectors. High-stakes tasks weight quality; routine tasks weight speed and cost. The vectors are updated during the weekly evolution cycle based on observed performance.

**Adaptations:**
- The paper focuses on tool selection within a single agent. We apply the same framework to agent-level routing in a multi-agent orchestration system.
- Preference vectors in the paper are static profiles. We make them dynamic, updating based on trajectory pool performance data during each evolution cycle.
- We reduce the dimensionality from the paper's five factors to three (quality, cost, speed) based on the observation that the remaining two (reliability, freshness) can be subsumed into quality for our use case.

---

### 10. AgentOrchestra: TEA Protocol

**Citation:** "AgentOrchestra: Training-Free Evolution of LLM-Based Multi-Agent Systems via TEA Protocol." _arXiv preprint, 2025._ [arXiv:2506.12508](https://arxiv.org/abs/2506.12508)

**Key Idea:** The TEA (Tool, Evolve, Adapt) protocol treats agents themselves as tools that can be composed, invoked, and replaced. This agent-as-tool abstraction enables the orchestration layer to dynamically compose multi-agent workflows without hardcoded pipelines. The evolution component allows the system to discover new agent compositions through experimentation, while the adaptation component adjusts compositions based on performance feedback. No training or fine-tuning is required.

**Our Implementation:** The agent-as-tool delegation system (see [Architecture](architecture.md), Section 2) implements three delegation modes: direct (single agent), pipeline (sequential chain), and parallel (concurrent fan-out with merge). The orchestrator selects the delegation mode based on task decomposition analysis. The weekly evolution cycle evaluates delegation mode effectiveness per task type and adjusts preferences accordingly.

**Adaptations:**
- The paper proposes fully autonomous composition discovery. We constrain composition to three predefined delegation modes, trading exploration capability for operational predictability.
- The TEA protocol includes a training phase for composition optimization. We rely entirely on heuristic feedback from the trajectory pool, consistent with our training-free constraint.
- We add a maker-checker loop (see [Architecture](architecture.md), Section 17) that validates delegated outputs before returning them to the orchestrator, adding a safety layer not present in the original protocol.

---

## Further Reading

The following papers provide additional context for specific subsystems but are not directly implemented in the current architecture:

1. **Voyager: An Open-Ended Embodied Agent with Large Language Models** -- Wang, G. et al., 2023. [arXiv:2305.16291](https://arxiv.org/abs/2305.16291). Pioneered the skill library pattern where agents accumulate reusable capabilities over time. Relevant to our skill discovery system.

2. **AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation** -- Wu, Q. et al., 2023. [arXiv:2308.08155](https://arxiv.org/abs/2308.08155). Established the conversational multi-agent framework pattern. Relevant to our agent communication design.

3. **Chain-of-Thought Prompting Elicits Reasoning in Large Language Models** -- Wei, J. et al., 2022. [arXiv:2201.11903](https://arxiv.org/abs/2201.11903). Foundational work on structured reasoning in LLMs. Underpins the step-by-step reflection format used throughout the system.

4. **Language Agent Tree Search** -- Zhou, A. et al., 2023. [arXiv:2310.04406](https://arxiv.org/abs/2310.04406). Combines LLM reasoning with Monte Carlo Tree Search for systematic exploration. Relevant to future work on trajectory revision strategies.

5. **Cognitive Architectures for Language Agents** -- Sumers, T. et al., 2024. [arXiv:2309.02427](https://arxiv.org/abs/2309.02427). Provides a unifying cognitive science framework (perception, memory, action, learning) for understanding agent architectures. Useful as a conceptual reference for the overall system design.

---

_Last updated: 2026-03-01_
