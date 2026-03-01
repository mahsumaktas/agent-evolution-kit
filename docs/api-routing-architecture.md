# Oracle API Routing Mimarisi

> Son güncelleme: 2026-02-07

## Katmanlar

```
┌─────────────────────────────────────────────┐
│  TIER 1: Claude Sonnet (Max abonelik)       │
│  Karmaşık reasoning, tool use, memory       │
│  Rate limit: ~50 req/5dk (tahmini)          │
├─────────────────────────────────────────────┤
│  TIER 2: Free LLMs (API)                    │
│  Basit sınıflandırma, özetleme, çeviri      │
│  Groq → Cerebras → Mistral → OpenRouter     │
├─────────────────────────────────────────────┤
│  TIER 3: Lokal/Token-free                   │
│  STT, cache, arama, veri işleme             │
│  whisper.cpp, Redis, Meilisearch, Python    │
└─────────────────────────────────────────────┘
```

## Model Routing Kuralları

### TIER 1 — Claude Sonnet (sadece bunlar için kullan)
- User ile doğrudan sohbet
- Tool use gerektiren işler (dosya yazma, cron, browser)
- Memory sistemi (memory_store, context-buffer)
- CikCik tweet yazma (kalite kritik)
- Kod yazma/review
- Karar gerektiren analiz

### TIER 2 — Free LLM (Claude'u bunlarla yormA)
| Görev | Provider | Model | Neden |
|-------|----------|-------|-------|
| Email sınıflandırma | Groq | Llama 70B | Hızlı, basit classification |
| Haber özetleme | Cerebras | Llama 70B | En hızlı, özet yeterli |
| Tweet analizi | Mistral | Mistral Small | 1B token/ay, bol |
| Sentiment analiz | Groq | Llama 70B | Basit, hızlı |
| Çeviri | Mistral | Mistral Large | İyi çeviri kalitesi |
| Spam filtre | Cerebras | Llama 8B | Çok basit iş, küçük model |
| İçerik önerisi | OpenRouter | DeepSeek R1 | Reasoning iyi |

### TIER 3 — Lokal/Token-free (API bile gereksiz)
| Görev | Araç | Maliyet |
|-------|------|---------|
| Ses→yazı (TR) | Groq Whisper → whisper.cpp | $0 |
| Ses→yazı (EN) | Groq Whisper → Voxtral → whisper.cpp | $0 |
| Full-text arama | Meilisearch | $0 |
| Cache/rate limit | Redis | $0 |
| Veri saklama | PostgreSQL | $0 |
| Dosya arama | ripgrep + fd | $0 |
| JSON işleme | jq + Python | $0 |
| Btrfs snapshot | snapper | $0 |

## Fallback Zinciri

```
STT:  Groq Whisper → Mistral Voxtral (EN) → whisper.cpp (lokal)
LLM:  Claude Sonnet → Groq Llama 70B → Cerebras → Mistral → OpenRouter
```

## Cron Job Optimizasyonu

### Mevcut: 53 job hepsi Sonnet
### Hedef: 53 job akıllı routing ile

| Cron Kategorisi | Adet | Önerilen Tier |
|----------------|------|---------------|
| Sabah/akşam briefing | 2 | TIER 1 (tool use lazım) |
| Email triage | 3 | TIER 2 prefilter + TIER 1 özet |
| CikCik tweet | 9 | TIER 1 (kalite kritik) |
| CikCik analiz | 4 | TIER 2 (veri işleme) |
| Scout/haber | 4 | TIER 2 prefilter + TIER 1 özet |
| Memory/maintenance | 6 | TIER 1 (tool use lazım) |
| Freelance tarama | 3 | TIER 2 tarama + TIER 1 değerlendirme |
| Health/finance | 4 | TIER 1 (kişisel, hassas) |
| Self-compound | 3 | TIER 1 (karmaşık reasoning) |
| Haftalık review | 8 | TIER 1 (analiz) |
| Tek seferlik hatırlatma | 7 | TIER 1 (basit ama tool use) |

### Hibrit Yaklaşım (email-triage örneği):
```
1. Python script: Gmail API → son emailleri çek (TOKEN-FREE)
2. Groq Llama 70B: Her email için önem skoru (1-5) ver (FREE LLM)
3. Redis: Skorları cache'le (TOKEN-FREE)
4. Claude Sonnet: Sadece skor≥4 olan emailleri özetle (TIER 1)
```

**Sonuç:** Claude yerine Groq 20 email sınıflandırır, Claude sadece 2-3 önemli emaili özetler.
Claude rate limit korunur, toplam maliyet $0.

## Redis Cache Stratejisi

```python
# Aynı soruyu 1 saat içinde tekrar sorma
cache_key = f"llm:{model}:{hash(prompt)}"
cached = redis.get(cache_key)
if cached:
    return cached
result = call_llm(prompt)
redis.setex(cache_key, 3600, result)
```

## Dosya Yapısı
```
~/automation/
├── api-router/
│   ├── router.py          # Akıllı model routing
│   ├── providers.py       # API provider'lar
│   ├── cache.py           # Redis cache layer
│   └── fallback.py        # Fallback zinciri
├── email-triage/
│   ├── fetch.py           # Gmail çek (token-free)
│   ├── classify.py        # Groq ile sınıfla (free)
│   └── summarize.sh       # Claude ile özetle (tier 1)
└── ...
```
