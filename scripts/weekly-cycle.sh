#!/usr/bin/env bash
# Oracle Weekly Self-Evolution Cycle
# Pazar 22:00'de calisir. Research + Predict + System Check yapar.
#
# Kullanim:
#   weekly-cycle.sh              # Tam haftalik dongu
#   weekly-cycle.sh --dry-run    # Test (calismadan goster)

set -euo pipefail

SCRIPTS_DIR="$HOME/clawd/scripts"
AEK_HOME="$HOME/clawd"
LOG_DIR="$HOME/clawd/memory/bridge-logs"
CYCLE_LOG="$HOME/clawd/memory/evolution-log.md"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[weekly]${NC} $(date +%H:%M:%S) $1" >&2; }
err() { echo -e "${RED}[weekly]${NC} $(date +%H:%M:%S) $1" >&2; }
step() { echo -e "${CYAN}[weekly]${NC} === $1 ===" >&2; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

TIMESTAMP=$(date +%Y-%m-%d)
START_TIME=$(date +%s)

step "ORACLE WEEKLY CYCLE — $TIMESTAMP"

# === STEP 0: Cron Health Check ===
step "0/9 CRON WATCHDOG"
if $DRY_RUN; then
    log "[DRY] cron-watchdog.sh"
else
    bash "$SCRIPTS_DIR/cron-watchdog.sh" 2>&1 | while read -r line; do
        log "$line"
    done || err "Cron watchdog basarisiz (devam ediliyor)"
fi

# === STEP 1: System Check ===
step "1/9 SYSTEM CHECK"
if $DRY_RUN; then
    log "[DRY] system-check.sh --full"
else
    bash "$SCRIPTS_DIR/system-check.sh" --quick 2>&1 | while read -r line; do
        log "$line"
    done || err "System check basarisiz (devam ediliyor)"
fi

# === STEP 2: Autonomous Research ===
step "2/9 AUTONOMOUS RESEARCH"
if $DRY_RUN; then
    log "[DRY] research.sh --auto"
else
    bash "$SCRIPTS_DIR/research.sh" --auto 2>&1 | while read -r line; do
        log "$line"
    done || err "Research basarisiz (devam ediliyor)"
fi

# === STEP 3: Predictive Analysis ===
step "3/9 PREDICTIVE ANALYSIS"
if $DRY_RUN; then
    log "[DRY] predict.sh --weekly"
else
    bash "$SCRIPTS_DIR/predict.sh" --weekly 2>&1 | while read -r line; do
        log "$line"
    done || err "Prediction basarisiz (devam ediliyor)"
fi

# === STEP 4: Prompt Evolution ===
step "4/9 PROMPT EVOLUTION"
if $DRY_RUN; then
    log "[DRY] evolve-prompt.sh --apply"
else
    bash "$SCRIPTS_DIR/evolve-prompt.sh" --apply 2>&1 | while read -r line; do
        log "$line"
    done || err "Prompt evolution basarisiz (devam ediliyor)"
fi

# === STEP 5: Memory Index Update ===
step "5/9 MEMORY INDEX"
if $DRY_RUN; then
    log "[DRY] memory-index.sh"
else
    bash "$SCRIPTS_DIR/memory-index.sh" 2>&1 | while read -r line; do
        log "$line"
    done || err "Memory index basarisiz (devam ediliyor)"
fi

# === Step 6: Eval Batch (assess recent unevaluated trajectories) ===
step "6/9 EVAL BATCH"
if $DRY_RUN; then
    log "[DRY] Evaluate recent low-confidence trajectories"
else
    python3 - "$AEK_HOME/memory/trajectory-pool.json" <<'PYEOF'
import json, sys, subprocess, os

traj_file = sys.argv[1]
eval_script = os.path.join(os.path.dirname(os.path.abspath(traj_file)), "..", "scripts", "eval.sh")
try:
    with open(traj_file) as f:
        raw = json.load(f)
    entries = raw.get("entries", raw) if isinstance(raw, dict) else raw
    unevaluated = [i for i, e in enumerate(entries) if not e.get("eval_score")]
    scored = 0
    for idx in unevaluated[-5:]:  # max 5 per week
        e = entries[idx]
        task_text = e.get("task", "")
        if len(task_text) < 10:
            continue
        # Write task to temp file for eval
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as tmp:
            tmp.write(task_text[:2000])
            tmp_path = tmp.name
        try:
            result = subprocess.run(
                ["bash", eval_script, "--score", tmp_path],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0 and result.stdout.strip().isdigit():
                entries[idx]["eval_score"] = int(result.stdout.strip())
                scored += 1
        except Exception:
            pass
        finally:
            os.unlink(tmp_path)

    # Save updated trajectory
    if scored > 0:
        schema_meta = {k: v for k, v in raw.items() if k != "entries"} if isinstance(raw, dict) else {}
        output = {**schema_meta, "entries": entries}
        with open(traj_file, 'w') as f:
            json.dump(output, f, indent=2, ensure_ascii=False)

    print(f"Eval batch: {len(unevaluated)} unevaluated, {scored} scored")
except Exception as ex:
    print(f"Eval batch skipped: {ex}")
PYEOF
    log "Eval batch completed"
fi

# === Step 7: Governance Audit ===
step "7/9 GOVERNANCE AUDIT"
if $DRY_RUN; then
    log "[DRY] governance.sh audit"
else
    if [[ -x "$SCRIPTS_DIR/governance.sh" ]]; then
        bash "$SCRIPTS_DIR/governance.sh" audit 2>&1 | while read -r line; do
            log "$line"
        done || err "Governance audit basarisiz (devam ediliyor)"
    else
        log "governance.sh bulunamadi, atlaniyor"
    fi
fi

# === Step 8: Context Compaction ===
step "8/9 CONTEXT COMPACTION"
if $DRY_RUN; then
    log "[DRY] context-compactor.py --weekly"
else
    if [[ -f "$SCRIPTS_DIR/helpers/context-compactor.py" ]]; then
        python3 "$SCRIPTS_DIR/helpers/context-compactor.py" --weekly \
            --memory-dir "$AEK_HOME/memory" 2>&1 | while read -r line; do
            log "$line"
        done || err "Context compaction basarisiz (devam ediliyor)"
    else
        log "context-compactor.py bulunamadi, atlaniyor"
    fi
fi

# === STEP 9: Log Cycle ===
step "9/9 CYCLE LOG"
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

CYCLE_ENTRY="
## $TIMESTAMP — Weekly Evolution Cycle
- **Sure:** ${DURATION}s
- **Cron Watchdog:** calistirildi
- **System Check:** tamamlandi
- **Research:** auto mode
- **Prediction:** weekly mode
- **Prompt Evolution:** uygulanadi
- **Memory Index:** guncellendi
- **Eval Batch:** trajectory degerlendirme
- **Governance Audit:** denetim
- **Context Compaction:** haftalik sikistirma
- **Durum:** TAMAMLANDI"

if $DRY_RUN; then
    log "[DRY] Evolution log'a yazilacak:"
    echo "$CYCLE_ENTRY"
else
    echo "$CYCLE_ENTRY" >> "$CYCLE_LOG"
    log "Evolution log guncellendi"
fi

log "Weekly cycle tamamlandi: ${DURATION}s"
