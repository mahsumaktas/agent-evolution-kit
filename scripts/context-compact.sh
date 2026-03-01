#!/usr/bin/env bash
# context-compact.sh — Context Compaction wrapper
# Calls context-compactor.py with the right memory dir.
#
# Usage:
#   context-compact.sh --stats
#   context-compact.sh --weekly --dry-run
#   context-compact.sh --weekly
#   context-compact.sh --pre-compact
#   context-compact.sh --post-compact
set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/clawd}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPACTOR="$SCRIPT_DIR/helpers/context-compactor.py"

if [[ ! -f "$COMPACTOR" ]]; then
    echo "[context-compact] HATA: $COMPACTOR bulunamadi" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "[context-compact] HATA: python3 bulunamadi" >&2
    exit 1
fi

python3 "$COMPACTOR" --memory-dir "$AEK_HOME/memory" "$@"
