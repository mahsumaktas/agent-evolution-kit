# Model Mimarisi v3.0 — Failover & Redundancy

> Son güncelleme: 2026-02-07
> 9 Provider, 18 Model, $0 Toplam Maliyet

---

## 🏗️ Provider Haritası

| # | Provider | Model Sayısı | API Type | Rate Limit | Güç |
|---|----------|-------------|----------|------------|-----|
| 1 | **Anthropic** (Claude Max) | 3 | anthropic-messages | ~100/5min | ⭐⭐⭐⭐⭐ |
| 2 | **Google** | 2 | google-generative-ai | 60/min (Flash), 50/gün (Pro) | ⭐⭐⭐⭐⭐ |
| 3 | **NVIDIA NIM** | 4 | openai-completions | ~5000/gün | ⭐⭐⭐⭐⭐ |
| 4 | **OpenRouter** | 2 | openai-completions | ~200/gün (free) | ⭐⭐⭐⭐ |
| 5 | **Groq** | 1 | openai-completions | 30/min, 14.4K/gün | ⭐⭐⭐⭐ |
| 6 | **Cerebras** | 1 | openai-completions | 30/min, 1M tok/gün | ⭐⭐⭐⭐ |
| 7 | **Mistral** | 2 | openai-completions | 1/sn, 500K tok/gün | ⭐⭐⭐ |

**Toplam:** 18 model, 9 provider (Anthropic + Google + NVIDIA + OpenRouter + Groq + Cerebras + Mistral)

---

## 🎯 Görev Bazlı Model Atama + Failover Zincirleri

### 1. 🧠 Yaratıcı Yazım (tweet, post, içerik üretimi)
```
Primary:   Sonnet (Claude)        → En iyi Türkçe/İngilizce kalite
Fallback1: Kimi K2.5 (OpenRouter) → 262K context, multimodal
Fallback2: DeepSeek V3.2 (NVIDIA) → Güçlü yazım, hızlı
Fallback3: Mistral Large 675B (NVIDIA) → Çok dilli
```

### 2. 🔬 Derin Araştırma & Analiz
```
Primary:   Gemini 2.5 Pro (Google) → 1M context, reasoning
Fallback1: Nemotron Ultra 253B (NVIDIA) → Reasoning, büyük model
Fallback2: Qwen3 235B (NVIDIA) → Reasoning, MoE
Fallback3: Kimi K2 Thinking (OpenRouter) → Reasoning chain
```

### 3. ⚡ Mekanik İşler (monitoring, sync, triage)
```
Primary:   Flash (Google)          → 1M context, hızlı, bedava
Fallback1: Mistral Small (Mistral) → Hafif, çok dilli
Fallback2: Cerebras Llama 70B     → Ultra hızlı inference
Fallback3: DeepSeek V3.2 (NVIDIA) → Genel amaçlı
```

### 4. 🏎️ Hız-Kritik (DM reply, sosyal medya etkileşim)
```
Primary:   Cerebras Llama 70B     → Wafer-scale, en hızlı inference
Fallback1: Groq Llama 70B         → LPU, çok hızlı
Fallback2: Flash (Google)          → Hızlı, büyük context
```

### 5. 💻 Kod Yazma & Debug
```
Primary:   Sonnet (Claude)        → En iyi kodlama modeli
Fallback1: Codestral (Mistral)    → 256K context, kod uzmanı
Fallback2: DeepSeek V3.2 (NVIDIA) → Güçlü kodlama
Fallback3: Qwen3 235B (NVIDIA)    → Kodda iyi
```

### 6. 📧 Email & Çok Dilli İşler
```
Primary:   Mistral Small (Mistral) → En iyi çok dilli, Türkçe email
Fallback1: Flash (Google)          → Hızlı, çok dilli
Fallback2: Mistral Large 675B (NVIDIA) → Aynı aile, daha güçlü
```

### 7. 💰 Finansal Analiz (Soros agent)
```
Primary:   Gemini 2.5 Pro (Google) → Reasoning, matematik
Fallback1: Nemotron Ultra 253B (NVIDIA) → Büyük model reasoning
Fallback2: Qwen3 235B (NVIDIA)    → Matematiksel reasoning
```

### 8. 🐦 Twitter/Sosyal Medya (CikCik agent)
```
Primary:   Flash (Google)          → Mekanik tweet işleri
Fallback1: Cerebras Llama 70B     → Reply hızı kritik
Fallback2: Groq Llama 70B         → Analitik
```

---

## 🔄 Failover Uygulama Stratejisi

### Yöntem: Wrapper Script + Cron İçi Talimat

AgentSystem'da native failover yok. 3 katmanlı strateji:

### Katman 1: Cron Prompt İçi Failover Talimatı
Her cron job'ın prompt'una eklenir:
```
⚠️ Eğer bir API çağrısı hata verirse veya yanıt alamazsan,
alternatif model kullanmayı dene. Failover sırası: [X → Y → Z]
```
*Avantaj:* Sıfır kod değişikliği
*Dezavantaj:* Agent'ın takdirine bağlı

### Katman 2: Provider Health Check Script
```bash
#!/bin/bash
# ~/automation/provider-health-check.sh
# Her saat çalışır, sonuç: /tmp/provider-health.json

providers=("google" "nvidia" "groq" "cerebras" "mistral" "openrouter")
# Her provider'a basit ping → up/down durumu
```

### Katman 3: Kritik Job Duplikasyonu
En kritik 5 job için farklı model ile yedek cron:
- sabah-briefing → primary: Sonnet, backup: Flash
- email-triage → primary: Mistral, backup: Flash
- analytics-agent-watchdog → primary: Flash, backup: Cerebras

---

## 📊 Mevcut Cron Dağılımı (55 Job)

| Model | Job Sayısı | Kullanım Alanı |
|-------|-----------|----------------|
| Flash (Google) | ~25 | Monitoring, sync, scout, hatırlatma |
| Sonnet (Claude) | ~8 | Briefing, rapor, yaratıcı iş (+ default fallback) |
| Cerebras | ~7 | Twitter reply, DM, sosyal medya |
| Gemini Pro | 3 | Derin araştırma |
| Mistral Small | 3 | Email triage |
| Groq | 2 | Analytics, deep learning |
| Default (Sonnet) | ~7 | Model belirtilmemiş job'lar |

### Optimizasyon Fırsatları
1. **Default model job'ları** (model belirtilmemiş ~7 job) → Flash'a taşı (Sonnet rate limit koruma)
2. **NVIDIA modelleri henüz kullanılmıyor** → Araştırma cron'larını NVIDIA'ya taşı (Google rate limit koruma)
3. **OpenRouter/Kimi kullanılmıyor** → Multimodal analiz cron'ları ekle

---

## 🛡️ Redundancy Matrisi

Her kritik fonksiyon en az 3 farklı provider ile yapılabilir:

| Fonksiyon | Provider 1 | Provider 2 | Provider 3 | Provider 4 |
|-----------|-----------|-----------|-----------|-----------|
| Chat/Yazım | Anthropic | NVIDIA | OpenRouter | Google |
| Reasoning | Google | NVIDIA | OpenRouter | — |
| Kod | Anthropic | Mistral | NVIDIA | — |
| Hızlı yanıt | Cerebras | Groq | Google | — |
| Çok dilli | Mistral | NVIDIA | Google | OpenRouter |
| Monitoring | Google | Cerebras | Mistral | NVIDIA |
| Araştırma | Google | NVIDIA | OpenRouter | — |

**Tek nokta arıza riski: SIFIR.** Her fonksiyonun en az 3 alternatifi var.

---

## 💡 Önerilen Aksiyon Planı

### Hemen Yapılacak
1. ✅ NVIDIA provider eklendi (4 model)
2. ✅ OpenRouter/Kimi eklendi (2 model)
3. [ ] Model belirtilmemiş 7 job'a model ata (Flash veya uygun alternatif)
4. [ ] Provider health check script yaz + systemd timer (her saat)
5. [ ] Kritik 3 job için backup cron oluştur

### Kısa Vadede
6. [ ] Araştırma cron'larından 1'ini NVIDIA Nemotron'a taşı (Google rate limit yayma)
7. [ ] Kimi K2.5 ile multimodal analiz cron'u ekle (görsel tweet analizi)
8. [ ] Cron prompt'larına failover talimatı ekle

### Uzun Vadede
9. [ ] AgentSystem'a native failover önerisi (GitHub issue)
10. [ ] Oracle A1 üzerinde Ollama → local model backup katmanı
11. [ ] Cost tracking dashboard (tokscale + cron)

---

## 📈 Provider Sağlık Metrikleri (Takip Edilecek)

| Metrik | Yöntem |
|--------|--------|
| API uptime | Health check script (her saat) |
| Response latency | Cron log parse |
| Rate limit hit oranı | Error log analiz |
| Token kullanımı | tokscale günlük rapor |
| Model kalitesi | Haftalık output review |

---

## 🔑 Alias Haritası (Hızlı Referans)

```
/model sonnet    → Claude Sonnet 4.5 (Anthropic)
/model opus46    → Claude Opus 4.6 (Anthropic)
/model haiku     → Claude Haiku 4.5 (Anthropic)
/model flash     → Gemini 3 Flash (Google)
/model gemini-pro → Gemini 2.5 Pro (Google)
/model groq      → Llama 3.3 70B (Groq)
/model cerebras  → Llama 3.3 70B (Cerebras)
/model mistral   → Mistral Small 3.1 (Mistral)
/model codestral → Codestral (Mistral)
/model kimi      → Kimi K2.5 (OpenRouter)
/model kimi-think → Kimi K2 Thinking (OpenRouter)
/model nemotron  → Nemotron Ultra 253B (NVIDIA)
/model deepseek  → DeepSeek V3.2 (NVIDIA)
/model qwen      → Qwen3 235B (NVIDIA)
```

---

*"Scripts for logic, models for judgment"* — Her provider'ın güçlü olduğu alan farklı.
Doğru işe doğru model, yedekle destekle. 🐕
