# Güvenlik Tarama Pipeline

## 🔗 Tailscale Lateral Movement Riski (2026-02-07)
**Kaynak:** @rahulsood — "The Tailscale Illusion" (x.com/rahulsood/status/2019830679769608537)

### Özet
Tailscale bağlantı sağlar, izolasyon sağlamaz. Agent ele geçirilirse tüm tailnet'e yayılabilir.

### Mevcut Durum
- SSH: ✅ Port 2847, key-only, no-root, fail2ban
- Tailscale ACL: ❌ Yok — tüm cihazlar birbirine erişebilir
- Tool policy: ⚠️ exec sınırsız
- Skill review: ✅ SkillGuard aktif

### TODO
- [ ] Tailscale ACL kur (tag:agent → sadece internet, tag:server → sadece orchestrator)
- [ ] Worker agent'lar (CikCik, Soros, Tithonos) için exec kısıtlaması
- [ ] Agent başına ayrı SSH key (şu an tek key)
- [ ] Filesystem write kısıtlaması (agent kendi workspace dışına yazamasın)

### Risk Seviyesi: DÜŞÜK-ORTA
- Marketplace'den skill yüklemiyoruz, SkillGuard var
- Ama ACL yokluğu teorik risk oluşturuyor

---

Proje güvenlik testi istendiğinde sırayla çalıştır:

## 1. Statik Analiz
- Python: `bandit -r src/ -f json`
- Shell: `shellcheck scripts/*.sh`
- JS/TS: `eslint --ext .js,.ts src/`

## 2. Bağımlılık Tarama
- Python: `pip audit` veya `safety check --json`
- Node: `npm audit --json`
- Container: `trivy image IMAGE_NAME -f json` (kurulursa)

## 3. Web Uygulama Testi
- Nmap: `nmap -sV -sC TARGET -oX scan.xml`
- Nuclei: `nuclei -u http://TARGET -severity critical,high -jsonl` (kurulursa)

## 4. Rapor
Tüm çıktıları birleştirip Türkçe güvenlik raporu oluştur:
- 🔴 Kritik bulgular (hemen düzeltilmeli)
- 🟠 Yüksek bulgular (bu sprint'te düzeltilmeli)
- 🟡 Orta bulgular (planlı)
- 🟢 Düşük bulgular (not al)

## Mevcut Araçlar
| Araç | Durum | Amaç |
|------|-------|------|
| bandit | ✅ Kurulu | Python güvenlik |
| shellcheck | ✅ Kurulu | Shell script analiz |
| eslint | ✅ Kurulu | JS/TS lint |
| nmap | ✅ Kurulu | Network tarama |
| nuclei | ❌ Lazım olunca | Vulnerability scanner |
| trivy | ❌ Lazım olunca | Container güvenlik |
