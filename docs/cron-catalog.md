# Cron Kataloğu

> Son güncelleme: 2026-02-06 03:45. Toplam: 32 aktif, 3 devre dışı, 7 launchd agent.
> Model dağılımı: Sonnet 28 job, Flash 4 job (Haiku kaldırıldı — Claude Max abonelik, rate limit odaklı)
> contextTokens: 100K | Tüm cron'lar: sessionTarget=isolated ✅

## Günlük — Oracle (9 job)

| Saat | İsim | Açıklama |
|------|------|----------|
| 02:00 | memory-decay-daily | Decay manager + summary rewriter (Python script) |
| 03:00 | memory-fact-extraction | Daily notes'tan atomic fact çıkarma (1x/gün) |
| 08:00, 13:00, 18:00 | email-triage | Gmail tarama, sonuçları dosyaya yaz (3x/gün) |
| 08:30 | sabah-briefing | Takvim + email + supplement + sağlık → Telegram |
| 09:00, 14:00, 20:00 | freelance-unified | Upwork/Fiverr/LinkedIn paralel tarama (3 subagent) |
| 20:00 | aksam-briefing | Günün özeti + yarın bekleyenler → Telegram |
| 23:00 | hachi-self-compound | Session tarama, öğrenim çıkarma, dosyalara yaz |

## Günlük — CikCik (9 job)

| Saat | İsim | Açıklama |
|------|------|----------|
| 02:00 | social-agent-gece-rutin | Takipçi/beğeni/bookmark analizi (checkpoint'li) |
| 03:00 | social-agentburda-learning | Deep learning: viral analiz, stil araştırması (EN) |
| 06:00 | morning-intel | AI haberleri tarama, tweet malzemesi hazırlama |
| 08:00 | social-agentburda-morning | @social-agentburda feed/reply/tweet (EN only) |
| 09:00 | muxamos-morning-tweet | @muxamos sabah tweet + Bluesky cross-post |
| 11:00 | blog-style-unified | sikkofield blog stil analizi (checkpoint'li) |
| 11:00, 18:00 | muxamos-reply-session | @muxamos reply + RT session |
| 12:00 | social-agentburda-midday | @social-agentburda öğle session (EN only) |
| 15:00 | muxamos-afternoon-tweet | @muxamos öğle tweet (quote/görsel rotasyonu) |
| 17:00 | social-agentburda-afternoon | @social-agentburda öğleden sonra (EN only) |
| 19:00 | muxamos-evening-tweet | @muxamos akşam tweet + Bluesky |
| 22:00 | social-agentburda-night | @social-agentburda gece kapanış (EN only) |
| 22:00 | daily-summary-22 | Her iki hesabın gün sonu metrikleri → Telegram |

## Haftalık — Oracle (12 job)

| Gün/Saat | İsim | Açıklama |
|-----------|------|----------|
| Pzt 07:30 | scout-pazartesi | GitHub releases, ClawdHub, Discord |
| Pzt 10:00 | ims-api-takip | IMS API entegrasyonu durum takibi |
| Çar 07:30 | scout-carsamba | Yeni model haberleri, fiyat/performans |
| Cum 07:30 | scout-cuma | Community, Reddit, HN |
| Cum 09:00 | health-weight-friday | Tartılma hatırlatması |
| Cum 16:00 | haftalik-rapor-can | Can'a haftalık iş raporu taslağı |
| Cte 10:00 | hachi-sohbet-cevap | CikCik'e haftalık sohbet yanıtı |
| Paz 02:00 | social-agentburda-weekly | @social-agentburda haftalık performance review |
| Paz 03:00 | haftalik-ai-tools | AI araçları haftalık araştırma |
| Paz 04:30 | haftalik-self-compound | Haftanın öğrenimleri, pattern çıkarma |
| Paz 05:00 | skill-scout-haftalik | ClawdHub yeni skill tarama |
| Paz 07:30 | scout-pazar-ozet | Haftanın ekosistem özeti |
| Paz 10:00 | health-weekly-review | Sağlık testleri overdue kontrolü |
| Paz 20:00 | haftalik-review-unified | Kişisel + Notion haftalık review (BİRLEŞTİRİLDİ) |
| Paz 23:00 | haftalik-bakim | Session temizliği, eski memory arşivleme |
| Paz 23:30 | weekly-memory-synthesis | Memory knowledge graph rewrite |

## Haftalık — CikCik (4 job)

| Gün/Saat | İsim | Açıklama |
|-----------|------|----------|
| Pzt 01:00 | weekly-analytics-deep | Derin tweet analizi, A/B test sonuçları |
| Pzt/Per 07:17 | networking-dm-strategy | Takipçi analizi, DM fırsatları |
| Cum 15:00 | agent-sohbet | CikCik → Oracle haftalık sohbet |
| Paz 03:00 | social-agent-haftalik-rapor | Tweet performans haftalık rapor |
| Paz 23:00 | source-accounts-update | Kaynak hesap listesi güncelleme |

## Aylık — Oracle (2 job)

| Gün/Saat | İsim | Açıklama |
|-----------|------|----------|
| Her ayın 1'i 10:00 | health-monthly-deep-review | Sağlık derin review + longevity araştırma |
| Her ayın 25'i 10:00 | finans-aylik-takip | Kredi/kart/asgari özet |

## Tek Seferlik (deleteAfterRun) — Oracle (4 job)

| Tarih | İsim | Açıklama |
|-------|------|----------|
| 10 Şub 09:00 | legal-toplanti-hatirlatma | OBUS offline firmalar legal toplantısı |
| 15 Şub 09:00 | auzef-bahar-kayit | Kayıt yenileme hatırlatması |
| 23 Şub 09:00 | auzef-bahar-ders-secimi | Ders seçimi |
| 5 Mar 09:00 | arac-takip-ucreti-mart | Can ile araç takip ücreti görüşmesi |
| 21 Nis 09:00 | auzef-bahar-vize | Vize sınavı hatırlatması |
| 2 Haz 09:00 | auzef-bahar-final | Final sınavı hatırlatması |
| 7 Tem 09:00 | auzef-bahar-butunleme | Bütünleme hatırlatması |

## Devre Dışı (3 job)

| İsim | Neden |
|------|-------|
| memory-decay-daily | launchd'a taşındı (com.hachi.memory-decay) |
| email-triage | launchd'a taşındı (com.hachi.email-triage) |

## macOS launchd (~/automation/)

| Plist | Script | Sıklık |
|-------|--------|--------|
| com.hachi.linkedin-connect | linkedin/auto_connect.py | Pzt-Per 09:00 |
| com.hachi.ai-learning-hub | ai-learning-hub/scraper.py | Günlük 08:00 |
| com.hachi.obilet-monitor | obilet/monitor.py | 6 saatte bir |
| com.hachi.daily-digest | digest/collector.py | Günlük 07:00 |
| com.hachi.memory-decay | memory-decay/run.sh | Günlük 02:00 |
| com.hachi.email-triage | email-triage/run.sh | 3x/gün 08,13,18 |
| com.hachi.bird-cookie-refresh | bird-cookie-refresh/run.sh | Günlük 07:00 |

## Saat Çizelgesi (Yoğunluk)

```
02:00 ██ memory-decay + social-agent-gece-rutin
03:00 ██ memory-fact-extraction + social-agentburda-learning
06:00 █  morning-intel
08:00 ███ email-triage + social-agentburda-morning
08:30 █  sabah-briefing
09:00 ██ muxamos-morning + freelance
11:00 ██ blog-style + muxamos-reply
12:00 █  social-agentburda-midday
13:00 █  email-triage
15:00 █  muxamos-afternoon
17:00 █  social-agentburda-afternoon
18:00 ██ email-triage + muxamos-reply
19:00 █  muxamos-evening
20:00 ██ aksam-briefing + freelance
22:00 ██ social-agentburda-night + daily-summary
23:00 █  hachi-self-compound
```
