#!/usr/bin/env bash
# Oracle System Check — Sistem durumu ve yonetim araci
# Oracle bu script ile bilgisayari denetler ve yonetir.
#
# Kullanim:
#   system-check.sh                    # Tam sistem raporu
#   system-check.sh --quick            # Hizli durum kontrolu
#   system-check.sh --disk             # Disk analizi
#   system-check.sh --gateway          # Gateway durumu
#   system-check.sh --cron             # Cron durumu
#   system-check.sh --cleanup          # Temizlik onerisi

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

MODE="${1:---full}"

# === SYSTEM INFO ===
system_info() {
    header "SISTEM BILGISI"
    echo "  Hostname: $(hostname)"
    echo "  macOS:    $(sw_vers -productVersion 2>/dev/null || echo '?')"
    echo "  Node:     $(node --version 2>/dev/null || echo 'YOK')"
    echo "  Python:   $(python3 --version 2>/dev/null || echo 'YOK')"
    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    echo "  Claude:   $($CLAUDE_BIN --version 2>/dev/null || echo 'YOK')"
    echo "  Uptime:   $(uptime | sed 's/.*up //' | sed 's/,.*//')"
}

# === DISK ===
disk_check() {
    header "DISK DURUMU"
    DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
    DISK_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')

    if [[ $DISK_PCT -lt 80 ]]; then
        ok "Disk kullanimi: ${DISK_PCT}% (${DISK_FREE} bos)"
    elif [[ $DISK_PCT -lt 90 ]]; then
        warn "Disk kullanimi: ${DISK_PCT}% (${DISK_FREE} bos) — temizlik onerilebilir"
    else
        fail "Disk kullanimi: ${DISK_PCT}% (${DISK_FREE} bos) — KRITIK, temizlik GEREKLI"
    fi

    # Large directories
    echo "  Buyuk dizinler:"
    du -sh ~/.agent-evolution/ 2>/dev/null | awk '{print "    ~/.agent-evolution/: "$1}'
    du -sh ~/.agent-evolution/ 2>/dev/null | awk '{print "    ~/.agent-evolution/: "$1}'
    du -sh ~/.agent-evolution/my-patches/ 2>/dev/null | awk '{print "    ~/.agent-evolution/my-patches/: "$1}'
    du -sh ~/.agent-evolution/session-archive/ 2>/dev/null | awk '{print "    ~/.agent-evolution/session-archive/: "$1}'
}

# === GATEWAY ===
gateway_check() {
    header "GATEWAY DURUMU"

    # Process
    GW_PID=$(pgrep -f agent-system 2>/dev/null | head -1)
    if [[ -n "$GW_PID" ]]; then
        ok "Gateway calisiyor (PID: $GW_PID)"
    else
        fail "Gateway CALISMYOR"
        return 1
    fi

    # Port
    if lsof -i :28643 -P 2>/dev/null | grep -q LISTEN; then
        ok "Port 28643 LISTEN"
    else
        fail "Port 28643 DINLENMIYOR"
    fi

    # LaunchAgent state
    STATE=$(launchctl print gui/$(id -u)/ai.agent-system.gateway 2>&1 | grep "state =" | head -1 | awk '{print $NF}')
    if [[ "$STATE" == "running" ]]; then
        ok "LaunchAgent state: $STATE"
    else
        warn "LaunchAgent state: $STATE"
    fi

    # Recent errors
    ERROR_COUNT=$(tail -100 ~/.agent-evolution/logs/gateway.log 2>/dev/null | grep -ic "error" | tail -1 || echo "0")
    ERROR_COUNT=$(echo "$ERROR_COUNT" | tr -d '[:space:]')
    if [[ $ERROR_COUNT -eq 0 ]]; then
        ok "Son 100 log satirinda 0 hata"
    else
        warn "Son 100 log satirinda $ERROR_COUNT hata"
    fi

    # Discord
    DISCORD_OK=$(tail -50 ~/.agent-evolution/logs/gateway.log 2>/dev/null | grep -c "logged in to discord" || echo "0")
    if [[ $DISCORD_OK -gt 0 ]]; then
        ok "Discord baglanti basarili ($DISCORD_OK bot)"
    else
        warn "Discord baglanti durumu belirsiz"
    fi
}

# === AGENTS ===
agent_check() {
    header "AGENT DURUMU"

    for agent_dir in ~/.agent-evolution/agents/*/; do
        agent=$(basename "$agent_dir")
        sessions=$(find "$agent_dir/sessions" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
        echo "  $agent: $sessions aktif session"
    done
}

# === CRON ===
cron_check() {
    header "CRON DURUMU"

    CRON_COUNT=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l | tr -d ' ')
    echo "  Aktif cron: $CRON_COUNT"
    crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while read line; do
        echo "    $line"
    done

    # LaunchAgents
    echo "  LaunchAgents:"
    for plist in ~/Library/LaunchAgents/ai.agent-system.*.plist; do
        name=$(basename "$plist" .plist)
        state=$(launchctl print gui/$(id -u)/$name 2>&1 | grep "state =" | head -1 | awk '{print $NF}' || echo "?")
        echo "    $name: $state"
    done
}

# === MEMORY/ORACLE ===
oracle_check() {
    header "ORACLE SELF-EVOLUTION"

    # Trajectory pool
    TRAJ_COUNT=$(python3 -c "import json; print(len(json.load(open('$HOME/clawd/memory/trajectory-pool.json')).get('entries',[])))" 2>/dev/null || echo "?")
    echo "  Trajectory pool: $TRAJ_COUNT kayit"

    # Reflections
    REF_COUNT=$(find ~/.agent-evolution/memory/reflections -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Reflections: $REF_COUNT dosya"

    # Knowledge
    KNOW_COUNT=$(find ~/.agent-evolution/memory/knowledge -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Knowledge base: $KNOW_COUNT dosya"

    # Tools
    if [[ -f ~/.agent-evolution/tools/catalog.json ]]; then
        TOOL_COUNT=$(python3 -c "import json; print(len(json.load(open('$HOME/clawd/tools/catalog.json')).get('tools',[])))" 2>/dev/null || echo "?")
        echo "  Generated tools: $TOOL_COUNT"
    else
        echo "  Generated tools: 0 (katalog henuz yok)"
    fi

    # Bridge logs
    BRIDGE_COUNT=$(find ~/.agent-evolution/memory/bridge-logs -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Bridge calls: $BRIDGE_COUNT"
}

# === CLEANUP SUGGESTIONS ===
cleanup_suggest() {
    header "TEMIZLIK ONERILERI"

    # Old session archives
    OLD_ARCHIVES=$(find ~/.agent-evolution/session-archive -maxdepth 1 -type d -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    [[ $OLD_ARCHIVES -gt 0 ]] && warn "$OLD_ARCHIVES eski session arsivi (30+ gun) — silinebilir"

    # Large log files
    LARGE_LOGS=$(find ~/.agent-evolution/logs -size +10M 2>/dev/null | wc -l | tr -d ' ')
    [[ $LARGE_LOGS -gt 0 ]] && warn "$LARGE_LOGS buyuk log dosyasi (10MB+) — rotate edilebilir"

    # Old dist backups
    OLD_DIST=$(find ~/.agent-evolution/my-patches -maxdepth 1 -name "dist-backup-*" -type d 2>/dev/null | wc -l | tr -d ' ')
    [[ $OLD_DIST -gt 2 ]] && warn "$OLD_DIST dist backup var — en eski $((OLD_DIST - 2))'si silinebilir"

    # Brew cleanup
    BREW_CACHE=$(du -sh "$(brew --cache)" 2>/dev/null | awk '{print $1}')
    [[ -n "$BREW_CACHE" ]] && echo "  Brew cache: $BREW_CACHE (brew cleanup ile temizlenebilir)"

    echo ""
    ok "Temizlik onerileri tamamlandi"
}

# === EXECUTE ===
case $MODE in
    --full)
        system_info
        disk_check
        gateway_check
        agent_check
        cron_check
        oracle_check
        cleanup_suggest
        ;;
    --quick)
        gateway_check
        agent_check
        ;;
    --disk)     disk_check; cleanup_suggest;;
    --gateway)  gateway_check;;
    --cron)     cron_check;;
    --cleanup)  cleanup_suggest;;
    --oracle)   oracle_check;;
    --help|-h)
        echo "Kullanim: system-check.sh [--full|--quick|--disk|--gateway|--cron|--cleanup|--oracle]"
        ;;
    *)
        echo "Bilinmeyen mod: $MODE"
        exit 1;;
esac

echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') — Oracle System Check tamamlandi"
