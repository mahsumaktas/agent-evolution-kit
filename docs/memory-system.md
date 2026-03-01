# Memory Sistemi

## Hybrid Mimari

### 1. Dosya Bazlı (Structured)
```
memory/
├── YYYY-MM-DD.md       → Günlük log
├── context-buffer.md   → Son aktif konular (her session başında oku)
├── projects/           → Proje bazlı hafıza (lazy load)
├── decisions/          → Alınan kararlar + bağlam
├── people/             → Kişi bazlı notlar
├── learnings/          → Günlük öğrenimler
├── weekly-reviews/     → Haftalık özetler
└── knowledge/          → Fact-based memory (hot/warm/cold)
```

### 2. Vector Memory (LanceDB)
- Uzun vadeli, semantic search
- autoCapture: false, autoRecall: true
- Provider: `gemini` (`gemini-embedding-001`)
- Store path: `~/.agent-evolution/memory-v2/{agentId}.sqlite`
- Remote batch: kapali (`memorySearch.remote.batch.enabled=false`)  
  Not: Gemini Batch endpoint sorunlarinda index kilitlenmesini engeller.
- Sync stratejisi:
  - `onSessionStart=false`
  - `onSearch=false`
  - `intervalMinutes=15`
- Gerekince manuel index: `agent-system memory index --agent <id> --force`
- memory_recall / memory_store araçları ile kullan

### 3. Notion (External)
- User'un doğrudan erişebileceği kalıcı bilgiler
- Compaction-proof: session silinse bile User ulaşabilir

## Okuma Kuralları (LAZY LOADING)
- Session başında: MEMORY.md + context-buffer.md (bootstrap'ta)
- Proje geçerse → `memory/projects/<proje>.md`
- Kişi geçerse → `memory/people/<isim>.md`
- Karar sorulursa → `memory/decisions/` tara
- **Tüm memory/ klasörünü eager loading YAPMA**

## Yazma Kuralları
| Ne | Nereye |
|----|--------|
| Kalıcı tercih/karar | MEMORY.md |
| Günlük not/log | memory/YYYY-MM-DD.md |
| Yeni proje | memory/projects/<slug>.md |
| Önemli karar | memory/decisions/YYYY-MM-DD-<konu>.md |
| Kişi bilgisi | memory/people/<isim>.md |
| Dış kaynak verisi | research/ (memory/ DEĞİL) |

## Compaction-Proof Kuralı (KRİTİK)
> Konuşulan her önemli bilgiyi ANINDA hem memory/'ye hem Notion'a yaz.
> RAM'deki her şey compaction'da silinir — dosyada olmayan bilgi ÖLÜ bilgidir.
> Test: "Session silinse User bu bilgiye ulaşabilir mi?" → Hayırsa YAZ.

## Knowledge Facts Sistemi
- `memory/knowledge/items.json` → atomic fact veritabanı
- Hot (≥0.7) / Warm (0.3-0.7) / Cold (<0.3) / Superseded
- Cron'lar: fact-extraction (6 saatte 1), decay-daily (02:00), weekly-synthesis (Pazar 23:30)
- Scripts: `~/.agent-evolution/scripts/memory/` (decay_manager.py, summary_rewriter.py, fact_extractor.py)
