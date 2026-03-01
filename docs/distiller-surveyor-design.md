# Distiller + Surveyor: Oracle Adaptasyonu

> Alfred'in en değerli 2 pattern'ini, mevcut stack'e (AgentSystem cron + LanceDB + markdown) sıfır migration ile uyarlama tasarımı.

## 🎯 Amaç

**Distiller**: memory/ ve research/ dosyalarını tarayıp implicit bilgiyi çıkart → `memory/distilled/` altına yaz.
**Surveyor**: LanceDB vector memory'deki kayıtları clusterla, ilişkilendir → `memory/clusters/` altına yaz.

Her ikisi de **haftalık cron** olarak çalışır, **mevcut yapıyı bozmaz**, Obsidian/Temporal gerektirmez.

---

## 1. DISTILLER — Knowledge Distillation

### 1.1 Alfred'den Ne Alıyoruz

| Alfred Özelliği | Bizim Adaptasyonumuz |
|---|---|
| 5 learning type (assumption, decision, constraint, contradiction, synthesis) | Aynısı — `memory/distilled/` altında |
| Two-pass pipeline (extract → meta-analyze) | Tek cron, iki aşamalı prompt |
| Keyword scanning (Stage 0) | `grep` pre-filter (Python/shell) |
| Scope enforcement (sadece learning record yarat) | Prompt-level kısıtlama |
| Content hash state tracking | `memory/distilled/.state.json` |

### 1.2 Kaynak Dosyalar (Taranacak)

```
~/.agent-evolution/memory/2026-*.md          # Günlük notlar (~50 dosya)
~/.agent-evolution/memory/reference/*.md     # Referans dosyalar (5 dosya)
~/.agent-evolution/memory/decisions/*.md     # Kararlar (3 dosya)
~/.agent-evolution/memory/projects/*.md      # Proje notları (27 dosya)
~/.agent-evolution/SESSION-STATE.md          # Aktif context
~/.agent-evolution/MEMORY.md                 # Kalıcı hafıza
~/.agent-evolution/research/nightly/*.md     # Araştırma raporları
~/.agent-evolution/research/reviewed/*.md    # İncelenmiş araştırmalar
```

**Toplam:** ~124 dosya, ~756KB. Hepsi taranabilir boyutta.

### 1.3 5 Learning Type (Bizim Kontekstimize Uyarlanmış)

| Type | Ne Yakalar | Örnek |
|---|---|---|
| **assumption** | Doğrulanmamış inanç/beklenti | "Upwork'te 5 review'dan sonra fiyat artırabiliriz" |
| **decision** | Alınmış ama formalize edilmemiş karar | "Haiku kullanma, her yerde Sonnet 4.6" |
| **constraint** | Sert limitler | "Claude Max 5 günde bitiyor, 2 gün fallback" |
| **contradiction** | Çelişen bilgiler | "MEMORY.md'de Oracle A1 'aktif' ama hâlâ alınamıyor" |
| **synthesis** | Birden fazla kaynaktan çıkan pattern | "3 ayrı projede aynı LanceDB sorunuyla karşılaştık" |

### 1.4 Pipeline

```
[Aşama 0: Pre-filter] ─── grep ile sinyal tarama (Python)
        │
        ▼
[Aşama 1: Extract] ────── LLM her kaynak dosyayı analiz eder
        │                   → JSON manifest üretir
        ▼
[Aşama 2: Dedup] ──────── Fuzzy title match + merge
        │
        ▼
[Aşama 3: Write] ──────── memory/distilled/ altına markdown yaz
        │
        ▼
[Aşama 4: Meta-Analysis] ─ Tüm learning'leri çapraz analiz et
                            → contradiction + synthesis bul
```

### 1.5 Pre-filter Sinyal Kelimeleri

```python
SIGNALS = {
    "decision": ["karar", "decided", "chose", "going with", "seçtik", "karar verdik", "geçildi"],
    "assumption": ["varsayım", "assuming", "expect", "beklentimiz", "muhtemelen", "probably"],
    "constraint": ["limit", "kısıt", "blocked", "cannot", "yapamayız", "engelliyor", "bitti"],
    "contradiction": ["ama", "ancak", "çelişki", "however", "conflict", "aksine", "aslında"],
    "synthesis": ["pattern", "trend", "tekrar", "consistently", "3. kez", "hep aynı", "ortak nokta"]
}
```

Her dosya için sinyal skoru hesaplanır. `min_signal_score >= 2` olan dosyalar Aşama 1'e gider.

### 1.6 Çıktı Formatı

```markdown
# memory/distilled/decision-model-sonnet46.md

---
type: decision
confidence: high
status: active
created: 2026-02-24
sources:
  - memory/2026-02-19.md
  - memory/reference/decisions.md
related:
  - memory/projects/treliq.md
---

## Karar: Tüm agentlar Sonnet 4.6'ya geçirildi

**Claim:** 20 Şubat 2026 itibarıyla tüm AgentSystem agent'ları (CikCik, Tithonos, Soros dahil)
Sonnet 4.6'ya geçirildi. Haiku kullanımı yasaklandı, Flash sadece araştırma cron'larında.

**Evidence:** "17 kalan Codex cron → Opus 4.6" (16 Şub) → "Tüm cron'lar Sonnet 4.6'ya geçirildi" (22 Şub)

**Context:** Claude Max $200/ay abonelik, token tasarrufu yerine kalite öncelikli.

**Supersedes:** Önceki karar (Flash/DeepSeek karma kullanım, 14 Şub)
```

### 1.7 State Tracking

```json
// memory/distilled/.state.json
{
  "last_run": "2026-02-24T03:00:00+03:00",
  "processed_sources": {
    "memory/2026-02-24.md": "a1b2c3hash",
    "memory/reference/decisions.md": "d4e5f6hash"
  },
  "learning_count": {
    "assumption": 5,
    "decision": 12,
    "constraint": 8,
    "contradiction": 3,
    "synthesis": 4
  }
}
```

Değişmeyen dosyalar tekrar taranmaz (content hash tracking).

---

## 2. SURVEYOR — Semantic Clustering

### 2.1 Alfred'den Ne Alıyoruz

| Alfred Özelliği | Bizim Adaptasyonumuz |
|---|---|
| Milvus Lite + HDBSCAN | **LanceDB** (zaten var!) + basit cosine clustering |
| Ollama embeddings | AgentSystem'un mevcut embedding'leri (Gemini) |
| Leiden community detection | Basit dosya referans graf analizi |
| LLM cluster labeling | Gemini Flash ile label (ucuz) |
| alfred_tags frontmatter | `memory/clusters/YYYY-MM.md` rapor dosyası |

### 2.2 Pipeline

```
[Aşama 1: Embed] ──── memory/ dosyalarını LanceDB'ye embed et
       │                (zaten var: memory_store ile yazılanlar)
       ▼
[Aşama 2: Cluster] ── Cosine similarity matrix → agglomerative clustering
       │                (scikit-learn, threshold=0.65)
       ▼
[Aşama 3: Label] ──── Her cluster için Flash ile 1-3 tag üret
       │
       ▼
[Aşama 4: Report] ── memory/clusters/2026-02.md rapor yaz
       │                + ilişki önerileri (related-to, contradicts, supersedes)
       ▼
[Aşama 5: Link] ───── LanceDB relatedTo alanlarını güncelle
                        (cognitive memory v2 patch kullanarak)
```

### 2.3 Clustering Yaklaşımı

Alfred Milvus + HDBSCAN kullanıyor. Biz zaten LanceDB'deyiz, daha basit:

```python
# 1. LanceDB'den tüm memory'leri çek
memories = table.search("*").limit(1000).to_list()

# 2. Embedding vektörlerini al
vectors = np.array([m["vector"] for m in memories])

# 3. Cosine similarity matrix
from sklearn.metrics.pairwise import cosine_similarity
sim_matrix = cosine_similarity(vectors)

# 4. Agglomerative clustering (threshold=0.65)
from sklearn.cluster import AgglomerativeClustering
clustering = AgglomerativeClustering(
    n_clusters=None,
    distance_threshold=0.35,  # 1 - 0.65 similarity
    metric="cosine",
    linkage="average"
)
labels = clustering.fit_predict(vectors)
```

**Neden HDBSCAN değil?** Memory sayımız ~200-500 arası. HDBSCAN büyük dataset'ler için. Agglomerative yeterli ve daha deterministik.

### 2.4 Rapor Formatı

```markdown
# memory/clusters/2026-02.md

## Cluster Raporu — Şubat 2026
> Oluşturulma: 2026-02-24 03:00 | Toplam: 187 memory | 14 cluster

### 🔴 Cluster 1: Model & Maliyet Kararları (23 kayıt)
**Tags:** `ai/model-selection`, `cost/optimization`, `decision/technical`

Öne çıkan kayıtlar:
- "Tüm cron'lar Sonnet 4.6'ya geçirildi" (decision)
- "Claude Max 5 günde bitiyor" (constraint)
- "Gemini modelleri OAuth üzerinden" (decision)

**İlişki önerileri:**
- 🔗 "Haiku yasaklandı" ↔ "Flash sadece araştırmada" (related-to)
- ⚡ "Codex cron → Opus 4.6" → "Sonnet 4.6 geçişi" (supersedes)

### 🟡 Cluster 2: Freelance & Ek Gelir (15 kayıt)
**Tags:** `career/freelance`, `income/side-projects`, `strategy/growth`
...

### 🟢 Cluster 3: Sağlık & Kilo Takibi (11 kayıt)
**Tags:** `health/weight-loss`, `health/medication`, `health/labs`
...

---

## 🔍 Çelişki Tespitleri
1. **Oracle A1:** MEMORY.md "aktif" yazıyor ↔ Günlük notlar "hâlâ alınamıyor" → DÜZELT
2. **Ofis günleri:** USER.md "Sal-Per" ↔ 18 Şub notu "Çar-Per değişikliği" → GÜNCELLE

## 🧩 Eksik Bağlantılar
- `memory/projects/partial-refund-v2.md` → `memory/2026-02-13.md` ilişkili ama bağlı değil
- `memory/people/bilal.md` → `memory/reference/finance.md` bağlantısı yok

## 📊 Orphan Kayıtlar (bağlantısız)
- memory/2026-02-12-2155.md (152 byte, muhtemelen stub)
- memory/2026-02-13-0403.md (152 byte, muhtemelen stub)
```

---

## 3. CRON TASARIMI

### 3.1 İki Cron, Haftalık

| Cron | Zamanlama | Agent | Model | Delivery |
|---|---|---|---|---|
| `knowledge-distiller` | Pazar 02:00 | memory-agent | Flash | #sistem |
| `knowledge-surveyor` | Pazar 03:00 | memory-agent | Flash | #sistem |

**Neden haftalık?** Memory ~750KB, haftada ~50KB büyüyor. Günlük gereksiz token harcar.
**Neden ayrı?** Distiller'ın çıktıları Surveyor'a girdi oluyor (distilled/ dosyaları da clusterlanır).

### 3.2 Distiller Cron Prompt

```
Sen Oracle'ın Knowledge Distiller worker'ısın.

GÖREV: ~/.agent-evolution/memory/ altındaki dosyaları tara, implicit (gizli/formalize edilmemiş) bilgiyi çıkart.

ADIMLAR:
1. Şu dizinleri tara: memory/2026-02-*.md, memory/reference/, memory/decisions/, memory/projects/, MEMORY.md
2. Her dosyada 5 sinyal türü ara:
   - assumption: "varsayım", "beklenti", "muhtemelen", "expect"
   - decision: "karar", "geçildi", "seçtik", "going with"
   - constraint: "limit", "kısıt", "engelliyor", "cannot"
   - contradiction: çelişen bilgiler (dosyalar arası kontrol!)
   - synthesis: tekrarlayan pattern'ler
3. memory/distilled/.state.json oku — önceden işlenmiş dosyaları atla (hash eşleşiyorsa)
4. Bulunan her learning için memory/distilled/<type>-<slug>.md yaz (YAML frontmatter + claim + evidence)
5. Pass B: Tüm learning'leri çapraz analiz et — contradiction ve synthesis bul
6. .state.json güncelle
7. Özet raporu #sistem'e yaz

KURALLAR:
- SADECE learning dosyası yarat. Mevcut dosyaları DEĞİŞTİRME.
- Bariz/yüzeysel bilgiyi yazma — sadece IMPLICIT, formalize edilmemiş olanları yaz.
- Her learning'e confidence (high/medium/low) ve kaynak dosya referansı ekle.
- Duplicate varsa merge et (aynı karar farklı günlerde yazılmışsa).
- Max 15 yeni learning/hafta (kalite > miktar).
```

### 3.3 Surveyor Cron Prompt

```
Sen Oracle'ın Knowledge Surveyor worker'ısın.

GÖREV: LanceDB memory'leri clusterla, ilişkilendir, rapor yaz.

ADIMLAR:
1. memory_recall ile geniş arama yap (5+ query: "karar", "proje", "sağlık", "finans", "teknik")
2. Her sonuç grubunu semantic cluster olarak değerlendir
3. memory/distilled/ dosyalarını da oku (Distiller çıktıları)
4. Cluster'ları etiketle (1-3 hierarchical tag)
5. Çelişki tespiti: MEMORY.md vs günlük notlar, USER.md vs güncel bilgi
6. Orphan tespiti: 200 byte altı dosyalar, bağlantısız kayıtlar
7. İlişki önerileri: birbiriyle ilgili ama bağlı olmayan kayıtlar
8. memory/clusters/2026-02.md rapor yaz (ayın son Pazar'ında)
9. Kritik çelişkileri anında düzeltme önerisi olarak listele

KURALLAR:
- Rapor yaz, kaynak dosyaları DEĞİŞTİRME.
- Çelişki bulunca "DÜZELT" flag'ı koy — Oracle sonraki session'da düzeltir.
- Orphan stub dosyaları listele (silinebilir).
- Max 20 cluster (çok atomik parçalama).
```

---

## 4. DOSYA YAPISI

```
~/.agent-evolution/memory/
├── distilled/                    # YENİ: Distiller çıktıları
│   ├── .state.json              # İşlenmiş dosya hash'leri
│   ├── assumption-upwork-5-review.md
│   ├── decision-model-sonnet46.md
│   ├── decision-telegram-dropped.md
│   ├── constraint-claude-max-5day.md
│   ├── contradiction-oracle-a1.md
│   └── synthesis-lancedb-recurring.md
├── clusters/                     # YENİ: Surveyor raporları
│   ├── 2026-02.md               # Aylık cluster raporu
│   └── 2026-03.md
├── 2026-02-24.md                # Mevcut (dokunulmaz)
├── reference/                    # Mevcut (dokunulmaz)
├── decisions/                    # Mevcut (dokunulmaz)
├── projects/                     # Mevcut (dokunulmaz)
└── people/                       # Mevcut (dokunulmaz)
```

---

## 5. MALİYET TAHMİNİ

| Bileşen | Token/Hafta | Maliyet |
|---|---|---|
| Distiller (Flash, ~124 dosya okuma + extraction) | ~200K input + ~20K output | ~$0.02 |
| Surveyor (Flash, memory_recall + rapor) | ~100K input + ~10K output | ~$0.01 |
| **Toplam haftalık** | **~330K token** | **~$0.03** |

**$0.03/hafta** — pratik olarak bedava (Gemini Flash OAuth = $0).

---

## 6. BEKLENEN DEĞER

1. **Çelişki tespiti**: MEMORY.md'deki eski/yanlış bilgiler otomatik flag'lenir
2. **Implicit decision formalization**: Cron'larda alınmış ama yazılmamış kararlar kayıt altına girer
3. **Pattern recognition**: "3 projede aynı LanceDB sorunu" gibi tekrarlayan sorunlar görünür olur
4. **Orphan cleanup**: Stub dosyalar tespit edilir
5. **Cross-reference**: İlişkili ama bağlı olmayan dosyalar birbirine bağlanır

---

## 7. UYGULAMA PLANI

| Adım | Ne | Süre |
|---|---|---|
| 1 | `memory/distilled/` ve `memory/clusters/` dizinleri oluştur | 1 dk |
| 2 | `knowledge-distiller` cron oluştur (Pazar 02:00, memory-agent, Flash) | 5 dk |
| 3 | `knowledge-surveyor` cron oluştur (Pazar 03:00, memory-agent, Flash) | 5 dk |
| 4 | İlk manual run yap (test) | 10 dk |
| 5 | Sonuçları review et, prompt tune | 15 dk |
| **Toplam** | | **~35 dk** |

---

*Tasarım: 24 Şub 2026 — Alfred (ssdavidai/alfred) Distiller + Surveyor pattern'lerinden uyarlanmıştır.*
