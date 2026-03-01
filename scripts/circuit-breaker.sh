#!/usr/bin/env bash
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# circuit-breaker.sh — Per-agent/per-tool circuit breaker state machine
# 3 state: CLOSED (normal) -> OPEN (blocked) -> HALF-OPEN (probe)
#
# Usage:
#   circuit-breaker.sh check <name>
#   circuit-breaker.sh record <name> <success|failure>
#   circuit-breaker.sh trip <name>
#   circuit-breaker.sh reset <name>
#   circuit-breaker.sh status
#   circuit-breaker.sh --help

set -euo pipefail

AEK_HOME="${AEK_HOME:-$HOME/agent-evolution-kit}"

STATE_FILE="$AEK_HOME/memory/circuit-breaker-state.json"

usage() {
    cat >&2 << 'EOF'
Circuit Breaker — Per-agent/per-tool state machine

Usage:
  circuit-breaker.sh check <name>              State check (exit 0=allowed, exit 1=blocked)
  circuit-breaker.sh record <name> <success|failure>  Record result
  circuit-breaker.sh trip <name>                Force OPEN
  circuit-breaker.sh reset <name>               Force CLOSED, reset counters
  circuit-breaker.sh status                     Show all breaker states

States:
  CLOSED     Normal — traffic allowed
  OPEN       Blocked — too many errors, waiting for cooldown
  HALF-OPEN  Probe — cooldown expired, single probe allowed

Defaults:
  threshold=3 (consecutive failure limit)
  cooldown=300s (OPEN duration)
EOF
    exit 1
}

if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    usage
fi

COMMAND="$1"
shift

exec python3 - "$STATE_FILE" "$COMMAND" "$@" <<'PYEOF'
import json
import sys
import os
from datetime import datetime, timezone

# === Args ===
state_file = sys.argv[1]
command = sys.argv[2]
args = sys.argv[3:]

# === Colors ===
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
NC = "\033[0m"

# === Defaults ===
DEFAULT_THRESHOLD = 3
DEFAULT_COOLDOWN = 300

def now_iso():
    return datetime.now(timezone.utc).isoformat()

def load_state():
    if os.path.exists(state_file):
        try:
            with open(state_file) as f:
                data = json.load(f)
            if isinstance(data, dict) and "breakers" in data:
                return data
        except (json.JSONDecodeError, ValueError):
            pass
    return {"breakers": {}}

def save_state(data):
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    with open(state_file, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_breaker(data, name):
    if name not in data["breakers"]:
        data["breakers"][name] = {
            "state": "CLOSED",
            "failure_count": 0,
            "consecutive_failures": 0,
            "last_failure": None,
            "last_state_change": now_iso(),
            "config": {
                "threshold": DEFAULT_THRESHOLD,
                "cooldown_seconds": DEFAULT_COOLDOWN
            }
        }
    return data["breakers"][name]

def effective_state(breaker):
    """If OPEN, check cooldown — return HALF-OPEN if expired."""
    if breaker["state"] != "OPEN":
        return breaker["state"]

    cooldown = breaker["config"]["cooldown_seconds"]
    last_change = breaker["last_state_change"]
    if last_change is None:
        return "OPEN"

    try:
        changed_at = datetime.fromisoformat(last_change)
        elapsed = (datetime.now(timezone.utc) - changed_at).total_seconds()
    except (ValueError, TypeError):
        return "OPEN"

    if elapsed >= cooldown:
        return "HALF-OPEN"
    return "OPEN"

def remaining_cooldown(breaker):
    """Remaining cooldown seconds for OPEN state."""
    if breaker["state"] != "OPEN":
        return 0
    cooldown = breaker["config"]["cooldown_seconds"]
    last_change = breaker["last_state_change"]
    if last_change is None:
        return cooldown
    try:
        changed_at = datetime.fromisoformat(last_change)
        elapsed = (datetime.now(timezone.utc) - changed_at).total_seconds()
    except (ValueError, TypeError):
        return cooldown
    rem = cooldown - elapsed
    return max(0, int(rem))

def state_color(state):
    if state == "CLOSED":
        return GREEN
    elif state == "OPEN":
        return RED
    elif state == "HALF-OPEN":
        return YELLOW
    return NC

# === Commands ===

if command == "check":
    if len(args) < 1:
        print(f"{RED}ERROR: 'check' command requires <name>{NC}", file=sys.stderr)
        sys.exit(1)

    name = args[0]
    data = load_state()
    breaker = get_breaker(data, name)
    eff = effective_state(breaker)

    # Persist OPEN->HALF-OPEN transition
    if eff == "HALF-OPEN" and breaker["state"] == "OPEN":
        breaker["state"] = "HALF-OPEN"
        breaker["last_state_change"] = now_iso()
        save_state(data)

    color = state_color(eff)
    print(f"{color}{BOLD}{name}{NC}: {color}{eff}{NC}", end="")

    if eff == "OPEN":
        rem = remaining_cooldown(breaker)
        print(f" (cooldown: {rem}s remaining)")
        save_state(data)
        sys.exit(1)
    else:
        print()
        save_state(data)
        sys.exit(0)

elif command == "record":
    if len(args) < 2:
        print(f"{RED}ERROR: 'record' command requires <name> <success|failure>{NC}", file=sys.stderr)
        sys.exit(1)

    name = args[0]
    result = args[1].lower()

    if result not in ("success", "failure"):
        print(f"{RED}ERROR: Result must be 'success' or 'failure', got: {result}{NC}", file=sys.stderr)
        sys.exit(1)

    data = load_state()
    breaker = get_breaker(data, name)
    eff = effective_state(breaker)

    # Persist OPEN->HALF-OPEN transition
    if eff == "HALF-OPEN" and breaker["state"] == "OPEN":
        breaker["state"] = "HALF-OPEN"
        breaker["last_state_change"] = now_iso()

    if result == "success":
        breaker["consecutive_failures"] = 0
        old_state = breaker["state"]
        if old_state in ("HALF-OPEN", "OPEN"):
            breaker["state"] = "CLOSED"
            breaker["last_state_change"] = now_iso()
        color = GREEN
        print(f"{color}[CB] {name}: {result} recorded{NC}", end="")
        if old_state != breaker["state"]:
            print(f" ({old_state} -> {breaker['state']})")
        else:
            print()

    elif result == "failure":
        breaker["failure_count"] += 1
        breaker["consecutive_failures"] += 1
        breaker["last_failure"] = now_iso()
        threshold = breaker["config"]["threshold"]

        old_state = breaker["state"]

        if breaker["state"] == "HALF-OPEN":
            # Probe failed — back to OPEN
            breaker["state"] = "OPEN"
            breaker["last_state_change"] = now_iso()
        elif breaker["state"] == "CLOSED" and breaker["consecutive_failures"] >= threshold:
            breaker["state"] = "OPEN"
            breaker["last_state_change"] = now_iso()

        color = RED if breaker["state"] == "OPEN" else YELLOW
        print(f"{color}[CB] {name}: {result} recorded (consecutive: {breaker['consecutive_failures']}/{threshold}){NC}", end="")
        if old_state != breaker["state"]:
            print(f" ({old_state} -> {breaker['state']})")
        else:
            print()

    save_state(data)

elif command == "trip":
    if len(args) < 1:
        print(f"{RED}ERROR: 'trip' command requires <name>{NC}", file=sys.stderr)
        sys.exit(1)

    name = args[0]
    data = load_state()
    breaker = get_breaker(data, name)
    old_state = breaker["state"]
    breaker["state"] = "OPEN"
    breaker["last_state_change"] = now_iso()
    save_state(data)
    print(f"{RED}[CB] {name}: OPEN (forced, previous: {old_state}){NC}")

elif command == "reset":
    if len(args) < 1:
        print(f"{RED}ERROR: 'reset' command requires <name>{NC}", file=sys.stderr)
        sys.exit(1)

    name = args[0]
    data = load_state()
    breaker = get_breaker(data, name)
    old_state = breaker["state"]
    breaker["state"] = "CLOSED"
    breaker["failure_count"] = 0
    breaker["consecutive_failures"] = 0
    breaker["last_failure"] = None
    breaker["last_state_change"] = now_iso()
    save_state(data)
    print(f"{GREEN}[CB] {name}: CLOSED (reset, previous: {old_state}){NC}")

elif command == "status":
    data = load_state()
    breakers = data.get("breakers", {})

    if not breakers:
        print(f"{YELLOW}No circuit breakers registered.{NC}")
        sys.exit(0)

    print(f"\n{BOLD}{CYAN}=== Circuit Breaker Status ==={NC}\n")

    for name, b in sorted(breakers.items()):
        eff = effective_state(b)
        color = state_color(eff)
        threshold = b["config"]["threshold"]
        cooldown = b["config"]["cooldown_seconds"]
        consec = b["consecutive_failures"]
        total = b["failure_count"]
        last_fail = b.get("last_failure") or "-"

        line = f"  {color}{BOLD}{name:20s}{NC} "
        line += f"state={color}{eff:10s}{NC} "
        line += f"failures={total} "
        line += f"consecutive={consec}/{threshold} "
        line += f"cooldown={cooldown}s"

        if eff == "OPEN":
            rem = remaining_cooldown(b)
            line += f" (remaining: {rem}s)"

        print(line)

        if last_fail != "-":
            print(f"  {'':20s} last_failure={last_fail}")

    print()

else:
    print(f"{RED}ERROR: Unknown command: {command}{NC}", file=sys.stderr)
    print(f"Usage: circuit-breaker.sh check|record|trip|reset|status", file=sys.stderr)
    sys.exit(1)
PYEOF
