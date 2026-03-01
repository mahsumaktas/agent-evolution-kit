# Oracle Orchestration v4 — Full Stack Architecture

> *"I see everything. I forget nothing. I adapt always."* 🦉

## 1. Sistem Genel Bakış

```
┌─────────────────────────────────────────────┐
│              Oracle (primary-agent)                │
│         Central Orchestrator 🦉              │
├─────────────────────────────────────────────┤
│  Blackboard (SQLite)    │  Event Bridge     │
│  ├─ State Store         │  ├─ LaunchAgent   │
│  ├─ Event Queue         │  ├─ 30s poll      │
│  └─ Task DAG            │  └─ Dispatcher    │
├─────────────────────────────────────────────┤
│  Agents (10)            │  Cron (42 jobs)   │
│  ├─ social-agent (social)     │  ├─ heartbeat     │
│  ├─ finance-agent (finance)     │  ├─ briefing      │
│  ├─ analytics-agent (ops)      │  ├─ research      │
│  ├─ assistant-agent (persona)  │  └─ maintenance   │
│  └─ 6 workers           │                   │
├─────────────────────────────────────────────┤
│  Memory v4 (LanceDB)   │  n8n (13 flows)   │
│  ├─ Self-pruning        │  ├─ webhooks      │
│  ├─ Entity graph        │  ├─ email brief   │
│  ├─ Cross-agent filter  │  └─ health check  │
│  └─ Access pattern log  │                   │
├─────────────────────────────────────────────┤
│  Browser (CDP)          │  Tools            │
│  ├─ Primary (18804)     │  ├─ Fabric (243)  │
│  ├─ Secondary (18805)   │  ├─ agent-browser │
│  ├─ Tertiary (18806)    │  ├─ gog (email)   │
│  └─ Headless (18807)    │  └─ pass (creds)  │
└─────────────────────────────────────────────┘
```

## 2. Shared Blackboard (`oracle-blackboard.sh`)

SQLite-backed inter-agent communication layer at `~/.agent-evolution/blackboard.db`.

### Komponentler
- **State Store**: Key-value pairs scoped by agent (`agent_id/key = value`)
- **Event Queue**: Pub/sub events with priority, source/target filtering, consumption tracking
- **Task Registry**: Hierarchical tasks with dependencies, status tracking, auto-unblock

### CLI
```bash
# State
oracle-blackboard.sh set "market.status" "open" finance-agent
oracle-blackboard.sh get "market.status" finance-agent
oracle-blackboard.sh list finance-agent

# Events (pub/sub)
oracle-blackboard.sh publish "task.request" '{"agent":"social-agent","task":"tweet"}' primary-agent social-agent
oracle-blackboard.sh consume social-agent 10     # Consumes and returns events
oracle-blackboard.sh peek 20               # Read-only view

# Tasks (DAG nodes)
oracle-blackboard.sh task-add finance-agent '{"type":"analyze","ticker":"AAPL"}'
oracle-blackboard.sh task-update 1 running
oracle-blackboard.sh task-update 1 done
oracle-blackboard.sh task-list finance-agent pending

# Maintenance
oracle-blackboard.sh stats
oracle-blackboard.sh gc 7                  # Clean consumed events >7 days
```

### Agent'lar Nasıl Kullanır
Cron job'larında veya session'larda:
```bash
# Başlangıçta durumu oku
STATUS=$(oracle-blackboard.sh get "oracle.directive" _global 2>/dev/null || echo "normal")

# Sonucu yaz
oracle-blackboard.sh set "finance-agent.last_analysis" "$(date +%Y-%m-%d)" finance-agent

# Önemli event yayınla
oracle-blackboard.sh publish "analysis.complete" '{"result":"bullish","ticker":"AAPL"}' finance-agent primary-agent
```

## 3. DAG Workflow Engine (`oracle-dag.sh`)

JSON-defined directed acyclic graph execution with dependency resolution.

### Workflow Format
```json
{
  "name": "morning-routine",
  "steps": [
    {"id": "health-check", "agent": "primary-agent", "action": "exec", "payload": "curl -sk https://localhost:28643/healthz", "depends": []},
    {"id": "fetch-news", "agent": "scout-agent", "action": "exec", "payload": "web_search 'AI news today'", "depends": []},
    {"id": "analyze", "agent": "finance-agent", "action": "spawn", "payload": "Analyze market sentiment", "depends": ["fetch-news"]},
    {"id": "tweet", "agent": "social-agent", "action": "exec", "payload": "scripts/agent-system-x-post.sh 'Market update'", "depends": ["analyze"]},
    {"id": "report", "agent": "primary-agent", "action": "notify", "payload": "Morning routine complete", "depends": ["health-check", "tweet"]}
  ]
}
```

### Action Types
| Action | Açıklama |
|--------|----------|
| `exec` | Shell komutu çalıştır |
| `spawn` | Agent session spawn et |
| `cron-run` | Cron job tetikle |
| `blackboard-set` | Blackboard state güncelle |
| `webhook` | HTTP POST gönder |
| `notify` | Bildirim gönder |

### CLI
```bash
oracle-dag.sh run workflow.json    # Execute DAG
oracle-dag.sh status my-workflow   # Check step statuses
oracle-dag.sh retry my-workflow    # Retry failed steps
oracle-dag.sh cancel my-workflow   # Cancel pending steps
oracle-dag.sh template             # Print example workflow
```

## 4. Event Bridge Daemon (`oracle-event-bridge.sh`)

LaunchAgent olarak 30 saniyede bir Blackboard'ı poll eder, event'leri dispatch eder.

### Desteklenen Event Tipleri
| Event Type | Aksiyon |
|------------|---------|
| `task.request` | Agent'a görev ilet |
| `agent.alert` | Kritikse metrics'e kaydet |
| `cron.trigger` | Cron job tetikle |
| `webhook.*` | HTTP POST forward |
| `n8n.trigger` | n8n webhook tetikle |
| `dag.*` | DAG event'lerini metrics'e logla |
| `bb.query` | Blackboard sorgusu çalıştır, sonucu publish et |

### LaunchAgent
- **Label:** `com.oracle.event-bridge`
- **Mode:** Daemon (KeepAlive, RunAtLoad)
- **Log:** `/tmp/oracle-event-bridge.log`

## 5. Parallel Browser (`oracle-parallel-browser.sh`)

Multi-profile Chrome CDP orchestration for concurrent web automation.

### Profiller
| Profil | Port | Kullanım |
|--------|------|----------|
| primary | 18804 | Login'li Chrome (Twitter, LinkedIn, IG) |
| secondary | 18805 | İkinci concurrent oturum |
| tertiary | 18806 | Üçüncü concurrent oturum |
| headless | 18807 | Headless otomasyon |

### CLI
```bash
oracle-parallel-browser.sh profiles     # List all profiles
oracle-parallel-browser.sh status       # Running instances
oracle-parallel-browser.sh launch secondary    # Start secondary
oracle-parallel-browser.sh kill secondary      # Stop secondary
oracle-parallel-browser.sh cleanup      # Kill all except primary
```

### Concurrent Kullanım
Primary → CikCik tweet atarken, Secondary → LinkedIn post, Tertiary → Upwork proposal.
**Kural:** Primary asla otomatik kill edilmez (login'li oturumlar).

## 6. Agent Factory (`oracle-agent-factory.sh`)

Dinamik agent oluşturma — workspace + SOUL.md + config.patch.

### CLI
```bash
oracle-agent-factory.sh list           # Show all agents
oracle-agent-factory.sh create test-agent "Test worker" flash
oracle-agent-factory.sh workspace test-agent
oracle-agent-factory.sh disable test-agent
```

### Akış
1. `create` → workspace dir + SOUL.md + BOOTSTRAP.md oluştur
2. Config patch JSON hazırla (`/tmp/agent-factory-<name>.json`)
3. `gateway config.patch` ile runtime'da agent ekle
4. Gateway restart → agent aktif

## 7. Model Routing Matrix

| Görev Tipi | Primary Model | Fallback | Neden |
|------------|---------------|----------|-------|
| Kritik karar/analiz | Opus 4.6 | Sonnet 4.6 | Reasoning |
| Araştırma (uzun) | Gemini 3 Pro | Qwen3 235B | 2M ctx, $0 |
| Tweet/post | DeepSeek V3.2 | Sonnet 4.6 | Hızlı, yaratıcı |
| Kod yazma | Qwen3 Coder 480B | Devstral 2 | $0, NVIDIA |
| Basit cron | Flash | DeepSeek | $0, hızlı |
| Consensus | 2 farklı model | — | Halüsinasyon önleme |

## 8. 15 AGI-Adjacent Patterns

### Pattern 1: Reflexion
Her hata sonrası analiz → ders çıkar → memory'ye yaz.
```
Hata → Analiz → Hipotez → Doğrulama → Prensip → memory/reflections/
```
**Script:** `oracle-evolve-prompt.sh`

### Pattern 2: Self-Refine (max 3 iterasyon)
Çıktıyı kendi kendine kritik et, max 3 tur iyileştir.
**Kural:** 3. turda hâlâ kötüyse → kabul et ve ilerle.

### Pattern 3: Planner-Executor-Verifier
1. Plan yaz (adımları listele)
2. Her adımı çalıştır
3. Sonucu doğrula
4. Başarısızsa → Plan'a dön

### Pattern 4: Sandbox Execution
Kod çalıştırmadan önce izole test.
**Script:** `oracle-sandbox.sh` (3-tier: jiti L1, tsc L2, canary L3)

### Pattern 5: Canary Deploy
Yeni kod → izole test → 60s monitoring → production veya rollback.
**Script:** `oracle-canary-deploy.sh`

### Pattern 6: SQLite Metrics
Per-agent performans takibi. Latency, error rate, success ratio.
**Script:** `oracle-metrics.sh`

### Pattern 7: Tri-Phase Briefing
Sabah (08:00) → Öğlen (13:00) → Akşam (18:00) brifing.
**Script:** `oracle-briefing.sh`

### Pattern 8: Activity Pattern Tracker
Enforced RAG'de `[pattern:category:id]` formatında access logging.
**Plugin:** memory-lancedb v4

### Pattern 9: Goal Decomposition (HTN)
Büyük hedef → alt görevlere böl → DAG ile çalıştır.
**Script:** `oracle-goal-decompose.sh`

### Pattern 10: Skill Discovery (Voyager-inspired)
Mevcut yetenekleri tara → eksikleri tespit et → skill template oluştur.
**Script:** `oracle-skill-discovery.sh`

### Pattern 11: Circuit Breaker
Ardışık N hata → agent'ı devre dışı bırak → cooldown → tekrar dene.
**Script:** `oracle-watchdog.sh` (L2→L3→L4 escalation)

### Pattern 12: Bi-Temporal Memory
Correction category (decay=0) + supersedes chain.
**Plugin:** memory-lancedb v3.1+

### Pattern 13: Prompt Self-Optimization
Correction event'lerden kural çıkar → prompt version snapshot.
**Script:** `oracle-evolve-prompt.sh` (v001+)

### Pattern 14: Maker-Checker Loop
Agent A çıktı üretir → Agent B review eder → Consensus yoksa → 3. agent.
**Uygulama:** Cross-agent sessions_send + blackboard

### Pattern 15: Progress Artifact
Her uzun görevde ara durum dosyası yaz → compaction'a dayanıklı.
**Dosyalar:** SESSION-STATE.md, context-buffer.md, memory/YYYY-MM-DD.md

## 9. Orchestration Akış Diyagramı

```
USER REQUEST
    │
    ▼
ORACLE (OODA Loop)
    │
    ├─── Basit? ──────────── Direkt cevapla
    │
    ├─── Araştırma? ──────── Gemini Pro subagent spawn
    │
    ├─── Multi-step? ─────── DAG workflow oluştur
    │         │
    │         ├── Step 1 → Agent A (exec)
    │         ├── Step 2 → Agent B (spawn) [depends: Step 1]
    │         └── Step 3 → Notify [depends: Step 1, Step 2]
    │
    ├─── Browser? ────────── CDP profil seç → agent-browser
    │
    ├─── Kod? ────────────── Sandbox test → canary deploy
    │
    └─── Tekrarlayan? ────── Cron job oluştur
              │
              └── 2. kez = script, 3. kez = cron
```

## 10. Dosya Haritası

```
~/.agent-evolution/
├── scripts/
│   ├── oracle-blackboard.sh      # Shared state + event queue
│   ├── oracle-dag.sh             # Workflow DAG runner
│   ├── oracle-event-bridge.sh    # Event dispatcher daemon
│   ├── oracle-parallel-browser.sh # Multi-CDP orchestration
│   ├── oracle-agent-factory.sh   # Dynamic agent creation
│   ├── oracle-watchdog.sh        # 4-tier self-healing
│   ├── oracle-metrics.sh         # SQLite perf tracking
│   ├── oracle-briefing.sh        # Tri-phase briefing
│   ├── oracle-goal-decompose.sh  # HTN goal decomposition
│   ├── oracle-skill-discovery.sh # Gap analysis
│   ├── oracle-sandbox.sh         # 3-tier plugin testing
│   ├── oracle-canary-deploy.sh   # Backup→canary→deploy
│   ├── oracle-bridge.sh          # Claude Code CLI bridge
│   ├── oracle-tool-gen.sh        # Autonomous tool generation
│   ├── oracle-predict.sh         # Predictive analysis
│   ├── oracle-research.sh        # Autonomous research
│   ├── oracle-system-check.sh    # System health
│   ├── oracle-evolve-prompt.sh   # Prompt versioning
│   └── oracle-consciousness.sh   # State snapshot
├── docs/
│   └── orchestration-v4.md       # This file
├── memory/
│   ├── prompt-versions/          # Prompt snapshots
│   ├── reflections/              # Per-agent learnings
│   └── trajectory-pool.json      # Success/fail trajectories
└── evals/
    └── hqs.py                    # Quality scoring

~/.agent-evolution/
├── blackboard.db                 # Shared state (SQLite)
├── workflows/                    # Saved DAG definitions
├── memory/lancedb/               # Vector memory
├── cron/jobs.json                # Cron definitions
└── agent-system.json                 # Main config

~/Library/LaunchAgents/
├── com.oracle.event-bridge.plist # Event bridge daemon
├── com.hachi.chrome-cdp.plist    # Primary CDP
└── ai.agent-system.gateway           # Gateway
```

## 11. Güvenlik Kuralları
- Primary CDP profili (18804) asla otomatik kill edilmez
- Blackboard'a API key/token yazılmaz
- Agent factory config.patch ile — direkt JSON write YASAK
- Plugin deploy → sandbox test zorunlu
- Destructive ops → backup + rollback planı

## 12. Monitoring
- `oracle-watchdog.sh` → Gateway health (launchd + port + log)
- `oracle-metrics.sh` → Per-agent latency, error rate
- `oracle-blackboard.sh stats` → Event/state metrics
- `evals/hqs.py` → Haftalık kalite skoru
- n8n Health Check workflow → 15dk interval

---

*Oracle Orchestration v4 — Built for autonomy, designed for oversight.* 🦉
*Son güncelleme: 2026-02-28*
