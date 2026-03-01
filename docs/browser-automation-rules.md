# Browser Automation Rules - KALICI BELLEK

Bu kurallar AgentSystem browser otomasyonunda zorunludur.

## 1) Target Lock
- Her akış başında `targetId` sabitle.
- Aynı işlem zincirinde hep aynı `--target-id` kullan.
- Tab değişirse yeni `targetId` al.

Doğrulama:
```bash
agent-system browser tabs --json
```

## 2) Dynamic DOM / Stale Ref
- Ref ID (`e12`, `e167`) kalıcı değildir.
- Her click/type öncesi taze snapshot alıp ref'i tekrar çöz.
- Ref hatasında `wait + snapshot + retry` uygula.

Doğrulama:
```bash
agent-system browser snapshot --browser-profile main --json --efficient --limit 200 --target-id <TARGET_ID>
```

## 3) Standart Scriptler
- Genel güvenli aksiyon motoru:
```bash
~/.agent-evolution/scripts/agent-system-browser-safe-action.sh --help
```
- X post akışı (stale-ref proof):
```bash
agent-system-x-post "metin"
agent-system-x-post --publish "metin"
```

## 4) X Post Akışı (zorunlu pratik)
1. Compose tabını target-lock et.
2. Textbox ref'ini role/name regex ile çöz.
3. Type et.
4. Publish butonunu tekrar snapshot ile çöz.
5. Disabled değilse click et.
6. Click fail olursa JS fallback (`data-testid=tweetButton*`).

## 5) Güvenlik
- Token/API key/şifre log veya memory dosyalarına yazma.
- Hassas verileri encrypted store'da tut.
- Konfigürasyon paylaşımlarında host/path bilgilerini anonimleştir.

## 6) Hızlı Sağlık Kontrolü
```bash
agent-system browser status --json
agent-system browser open https://x.com/compose/post --json
agent-system browser snapshot --browser-profile main --json --efficient --limit 200
```

Son güncelleme: 2026-02-08
