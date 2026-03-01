#!/usr/bin/env bash
# health-summary.sh — Oracle script'lerinin son çalışma zamanı ve durumu
# Kullanım: ./health-summary.sh [--json]
# Bash 3.2 uyumlu (macOS default)

TMP="/tmp"
NOW=$(date +%s)
JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

# ── Script tanımları: "isim|log_yolu|max_ok_saniye" ──────────────────────────
ENTRIES=(
  "briefing|$TMP/briefing.log|43200"
  "briefing-cron|$TMP/briefing-cron.log|43200"
  "cron-self-healer|$TMP/cron-self-healer.log|86400"
  "daily-check|$TMP/daily-check.log|86400"
  "event-bridge|$TMP/event-bridge.log|7200"
  "governance|$TMP/governance.log|14400"
  "metrics|$TMP/metrics.log|86400"
  "sandbox|$TMP/sandbox.log|604800"
  "system-check|$TMP/system-check.log|86400"
  "watchdog|$TMP/watchdog.log|3600"
)

WATCHDOG_STATE="$TMP/watchdog-state.json"

# ── Yardımcılar ───────────────────────────────────────────────────────────────
log_age_str() {
  local logfile="$1"
  [[ ! -f "$logfile" ]] && echo "never" && return
  local mtime diff
  mtime=$(stat -f %m "$logfile" 2>/dev/null || stat -c %Y "$logfile" 2>/dev/null)
  diff=$(( NOW - mtime ))
  if   (( diff < 60 ));    then echo "${diff}s ago"
  elif (( diff < 3600 ));  then echo "$(( diff/60 ))m ago"
  elif (( diff < 86400 )); then echo "$(( diff/3600 ))h ago"
  else                          echo "$(( diff/86400 ))d ago"
  fi
}

status_icon() {
  local logfile="$1" max_ok_secs="${2:-86400}"
  [[ ! -f "$logfile" ]] && echo "⚫" && return
  local mtime diff
  mtime=$(stat -f %m "$logfile" 2>/dev/null || stat -c %Y "$logfile" 2>/dev/null)
  diff=$(( NOW - mtime ))
  if   (( diff <= max_ok_secs ));     then echo "🟢"
  elif (( diff <= max_ok_secs*2 ));   then echo "🟡"
  else                                     echo "🔴"
  fi
}

last_line() {
  local logfile="$1" chars="${2:-40}"
  [[ ! -f "$logfile" ]] && echo "(log yok)" && return
  local line
  line=$(tail -1 "$logfile" 2>/dev/null | tr -d '\r')
  line=$(echo "$line" | sed 's/^\[.*\] //' | sed 's/^[0-9T:+.-]\{10,\} //' | sed 's/\x1b\[[0-9;]*m//g')
  echo "${line:0:$chars}"
}

# ── JSON çıktı ────────────────────────────────────────────────────────────────
if $JSON_MODE; then
  echo "{"
  echo "  \"generated\": \"$(date -Iseconds)\","
  echo "  \"scripts\": {"
  local_first=true
  for entry in "${ENTRIES[@]}"; do
    IFS='|' read -r name logfile max_secs <<< "$entry"
    age=$(log_age_str "$logfile")
    icon=$(status_icon "$logfile" "$max_secs")
    last=$(last_line "$logfile" 80 | sed 's/"/\\"/g')
    $local_first || printf ","
    printf '\n    "%s": {"log": "%s", "age": "%s", "status": "%s", "last_line": "%s"}' \
      "$name" "$logfile" "$age" "$icon" "$last"
    local_first=false
  done
  printf '\n  }\n}\n'
  exit 0
fi

# ── Human çıktı ───────────────────────────────────────────────────────────────
echo "🦉 Oracle Script Health Summary — $(date '+%Y-%m-%d %H:%M')"
printf '%.0s─' {1..72}; echo
printf "%-20s %-4s %-10s %-36s\n" "SCRIPT" "ST" "LAST RUN" "ÖZET"
printf '%.0s─' {1..72}; echo

total=0; existing=0
for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r name logfile max_secs <<< "$entry"
  age=$(log_age_str "$logfile")
  icon=$(status_icon "$logfile" "$max_secs")
  last=$(last_line "$logfile" 36)
  printf "%-20s %-4s %-10s %-36s\n" "$name" "$icon" "$age" "$last"
  (( total++ )) || true
  [[ -f "$logfile" ]] && (( existing++ )) || true
done

printf '%.0s─' {1..72}; echo

# Watchdog JSON state
if [[ -f "$WATCHDOG_STATE" ]]; then
  python3 -c "
import json
d=json.load(open('$WATCHDOG_STATE'))
print(f\"📊 watchdog: {d.get('last_status','?')} | fails: {d.get('fail_count',0)} | last: {d.get('last_check_human','?')}\")" 2>/dev/null || true
fi

echo "📁 $existing/$total script log aktif"
printf '%.0s─' {1..72}; echo
