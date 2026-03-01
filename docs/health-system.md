# Sağlık Takip Sistemi

Peter Attia longevity framework temelinde, proaktif ve evidence-based yaklaşım.

## Dosya Yapısı
```
systems/health/
├── data/test-schedule.json  → Testler, tarihler, durumlar
├── data/weight-log.json     → Kilo takibi
├── supplements.md           → Supplement protokolü
└── profile.md               → Sağlık profili (boy, kilo, bulgular)
```

## Test Schedule
- `data/test-schedule.json` — 15 test takip ediliyor
- Status: `ok`, `due_soon`, `overdue`, `never_done`
- Hesaplama: `lastDone + frequencyMonths < bugün → overdue`
- User test yaptırdığında → `lastDone` güncelle, status yeniden hesapla

## Supplements
- Sabah: D Vitamini 5000 IU + Omega-3 (yemekle)
- Sabah briefing'de hatırlat

## Kurallar
- Test yaptırdı → test-schedule.json güncelle
- Yeni supplement → supplements.md güncelle
- Kilo değişikliği → profile.md + weight-log.json güncelle
- Haftalık review'da tüm testler OK ise → bildirim YAPMA
- Sağlık verisi → `systems/health/` klasörüne (memory/ DEĞİL)

## Cron'lar
| Cron | Saat | Görev |
|------|------|-------|
| sabah-briefing | 08:30 | Supplement hatırlatma + geciken test |
| health-weight-friday | Cuma 09:00 | Tartılma hatırlatması |
| health-weekly-review | Pazar 10:00 | Geciken testler, egzersiz |
| health-monthly-deep-review | Ayın 1'i 10:00 | Tam protokol + araştırma |
